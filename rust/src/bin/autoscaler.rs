use std::{
    collections::BTreeSet,
    env,
    net::SocketAddr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use anyhow::{Context, Result, bail};
use axum::{Router, extract::State, http::StatusCode, response::IntoResponse, routing::get};
use chrono::Utc;
use futures::{StreamExt, TryStreamExt};
use k8s_openapi::api::{apps::v1::StatefulSet, core::v1::Pod};
use kube::{
    Api, Client, ResourceExt,
    runtime::{
        WatchStreamExt,
        watcher::{self, Event},
    },
};
use prometheus_client::{
    encoding::text::encode,
    metrics::{counter::Counter, gauge::Gauge},
    registry::Registry,
};
use symphony_control_plane::{
    autoscaling::{AutoscalerConfig, reconcile_plan},
    env::{i64 as env_i64, string as env_string, u32 as env_u32, u64 as env_u64},
    kubernetes::{current_replicas, pod_ready, set_replicas},
    symphony::SymphonyClient,
};
use tokio::{
    sync::RwLock,
    time::{MissedTickBehavior, interval},
};
use tracing::{error, info, warn};

const WATCH_SERVER_TIMEOUT_SECONDS: u32 = 60;
const WATCH_PROGRESS_TIMEOUT: Duration = Duration::from_secs(75);

#[derive(Clone)]
struct Settings {
    namespace: String,
    pod_selector: String,
    poll_interval: Duration,
    bind: SocketAddr,
    autoscaler: AutoscalerConfig,
    symphony: SymphonyClient,
}

#[derive(Clone)]
struct AppState {
    registry: Arc<Mutex<Registry>>,
    watcher_ready: Arc<AtomicBool>,
    reconcile_ready: Arc<AtomicBool>,
}

#[derive(Clone)]
struct Metrics {
    current_workers: Gauge,
    desired_workers: Gauge,
    eligible_issues: Gauge,
    ready_workers: Gauge,
    reconciliations: Counter,
    failures: Counter,
}

impl Metrics {
    fn register(registry: &mut Registry) -> Self {
        let metrics = Self {
            current_workers: Gauge::default(),
            desired_workers: Gauge::default(),
            eligible_issues: Gauge::default(),
            ready_workers: Gauge::default(),
            reconciliations: Counter::default(),
            failures: Counter::default(),
        };
        registry.register(
            "symphony_autoscaler_current_workers",
            "Current StatefulSet replicas.",
            metrics.current_workers.clone(),
        );
        registry.register(
            "symphony_autoscaler_desired_workers",
            "Desired worker replicas.",
            metrics.desired_workers.clone(),
        );
        registry.register(
            "symphony_autoscaler_eligible_issues",
            "Latest eligible Symphony issue demand.",
            metrics.eligible_issues.clone(),
        );
        registry.register(
            "symphony_autoscaler_ready_workers",
            "Ready worker pods observed by the Kubernetes watcher.",
            metrics.ready_workers.clone(),
        );
        registry.register(
            "symphony_autoscaler_reconciliations_total",
            "Successful autoscaler reconciliations.",
            metrics.reconciliations.clone(),
        );
        registry.register(
            "symphony_autoscaler_failures_total",
            "Failed autoscaler reconciliations.",
            metrics.failures.clone(),
        );
        metrics
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "symphony_autoscaler=info,warn".into()),
        )
        .init();

    let settings = Settings::from_env()?;
    let client = Client::try_default()
        .await
        .context("load in-cluster Kubernetes configuration")?;
    let statefulsets: Api<StatefulSet> = Api::namespaced(client.clone(), &settings.namespace);
    let pods: Api<Pod> = Api::namespaced(client, &settings.namespace);

    let ready_hosts = Arc::new(RwLock::new(BTreeSet::new()));
    let watcher_ready = Arc::new(AtomicBool::new(false));
    let reconcile_ready = Arc::new(AtomicBool::new(false));
    let mut registry = Registry::default();
    let metrics = Metrics::register(&mut registry);
    let app_state = AppState {
        registry: Arc::new(Mutex::new(registry)),
        watcher_ready: watcher_ready.clone(),
        reconcile_ready: reconcile_ready.clone(),
    };

    tokio::spawn(serve(settings.bind, app_state));
    tokio::spawn(watch_ready_pods(
        pods,
        settings.pod_selector.clone(),
        ready_hosts.clone(),
        watcher_ready.clone(),
    ));

    let mut ticker = interval(settings.poll_interval);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        ticker.tick().await;
        if !watcher_ready.load(Ordering::Acquire) {
            reconcile_ready.store(false, Ordering::Release);
            metrics.failures.inc();
            warn!("worker pod watch is not initialized; retaining capacity");
            continue;
        }

        let ready_snapshot = ready_hosts.read().await.clone();
        metrics.ready_workers.set(as_i64(ready_snapshot.len()));

        match reconcile(&settings, &statefulsets, &ready_snapshot, &metrics).await {
            Ok(()) => {
                reconcile_ready.store(true, Ordering::Release);
                metrics.reconciliations.inc();
            }
            Err(error) => {
                reconcile_ready.store(false, Ordering::Release);
                metrics.failures.inc();
                error!(error = %error, "autoscaler reconciliation failed; retaining capacity");
            }
        }
    }
}

impl Settings {
    fn from_env() -> Result<Self> {
        let namespace = env_string("POD_NAMESPACE", "symphony");
        let statefulset = env_string("STATEFULSET_NAME", "symphony-worker");
        let minimum = env_u32("MIN_WORKERS", 0)?;
        let maximum = env_u32("MAX_WORKERS", 10)?;
        if minimum > maximum {
            bail!("MIN_WORKERS cannot exceed MAX_WORKERS");
        }

        let agents_per_worker = env_u32("AGENTS_PER_WORKER", 1)?;
        if agents_per_worker == 0 {
            bail!("AGENTS_PER_WORKER must be positive");
        }
        let drain_token = env::var("SYMPHONY_WORKER_DRAIN_TOKEN").context("missing drain token")?;
        if drain_token.len() < 32 {
            bail!("drain token must be at least 32 characters");
        }

        Ok(Self {
            namespace,
            pod_selector: env_string("WORKER_POD_SELECTOR", "app=symphony-worker"),
            poll_interval: Duration::from_secs(env_u64("POLL_INTERVAL_SECONDS", 15)?),
            bind: env_string("METRICS_BIND", "0.0.0.0:8080")
                .parse()
                .context("invalid METRICS_BIND")?,
            autoscaler: AutoscalerConfig {
                minimum,
                maximum,
                agents_per_worker,
                demand_max_age_seconds: env_i64("DEMAND_MAX_AGE_SECONDS", 300)?,
                statefulset,
            },
            symphony: SymphonyClient::new(
                env_string(
                    "SYMPHONY_STATE_URL",
                    "http://symphony-orchestrator:4000/api/v1/state",
                ),
                env_string(
                    "SYMPHONY_DRAINS_URL",
                    "http://symphony-orchestrator:4000/api/v1/worker-drains",
                ),
                drain_token,
            )?,
        })
    }
}

async fn reconcile(
    settings: &Settings,
    statefulsets: &Api<StatefulSet>,
    ready_hosts: &BTreeSet<String>,
    metrics: &Metrics,
) -> Result<()> {
    let (state, current) = tokio::try_join!(
        async {
            settings
                .symphony
                .state()
                .await
                .context("read Symphony state")
        },
        async {
            current_replicas(statefulsets, &settings.autoscaler.statefulset)
                .await
                .context("read worker StatefulSet replicas")
        }
    )?;
    let plan = reconcile_plan(
        &state,
        current,
        ready_hosts,
        Utc::now(),
        &settings.autoscaler,
    )?;

    metrics.current_workers.set(i64::from(current));
    metrics.desired_workers.set(i64::from(plan.desired));
    metrics
        .eligible_issues
        .set(i64::from(state.demand.eligible));

    let active_drained_hosts = if same_hosts(&state.worker_pool.drained_hosts, &plan.drains) {
        active_drained_hosts(&state, &plan.drains)
    } else {
        settings
            .symphony
            .set_drains(&plan.drains)
            .await?
            .active_drained_hosts
    };
    if plan.desired < current && !active_drained_hosts.is_empty() {
        info!(
            current,
            desired = plan.desired,
            active_drained_hosts = ?active_drained_hosts,
            "scale-down deferred until drained workers are session-free"
        );
        return Ok(());
    }

    if let Some(desired) = plan.scale_to {
        set_replicas(statefulsets, &settings.autoscaler.statefulset, desired).await?;
        info!(
            current,
            desired,
            drains = ?plan.drains,
            "worker StatefulSet scaled"
        );
    } else {
        info!(
            current,
            desired = plan.desired,
            drains = ?plan.drains,
            "worker capacity reconciled"
        );
    }
    Ok(())
}

fn same_hosts(left: &[String], right: &[String]) -> bool {
    left.iter().collect::<BTreeSet<_>>() == right.iter().collect::<BTreeSet<_>>()
}

fn active_drained_hosts(
    state: &symphony_control_plane::symphony::SymphonyState,
    drains: &[String],
) -> Vec<String> {
    let drains = drains.iter().map(String::as_str).collect::<BTreeSet<_>>();
    state
        .running
        .iter()
        .chain(&state.retrying)
        .filter_map(|entry| entry.worker_host.as_deref())
        .filter(|host| drains.contains(host))
        .map(str::to_owned)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

async fn watch_ready_pods(
    pods: Api<Pod>,
    selector: String,
    ready_hosts: Arc<RwLock<BTreeSet<String>>>,
    watcher_ready: Arc<AtomicBool>,
) {
    loop {
        let mut stream = watcher::watcher(
            pods.clone(),
            watcher::Config::default()
                .labels(&selector)
                .timeout(WATCH_SERVER_TIMEOUT_SECONDS),
        )
        .default_backoff()
        .boxed();
        let mut initial = BTreeSet::new();

        loop {
            match tokio::time::timeout(WATCH_PROGRESS_TIMEOUT, stream.try_next()).await {
                Ok(Ok(Some(Event::Init))) => {
                    initial.clear();
                    watcher_ready.store(false, Ordering::Release);
                }
                Ok(Ok(Some(Event::InitApply(pod)))) => {
                    update_ready_set(&mut initial, &pod);
                }
                Ok(Ok(Some(Event::InitDone))) => {
                    *ready_hosts.write().await = initial.clone();
                    watcher_ready.store(true, Ordering::Release);
                }
                Ok(Ok(Some(Event::Apply(pod)))) => {
                    let mut hosts = ready_hosts.write().await;
                    update_ready_set(&mut hosts, &pod);
                }
                Ok(Ok(Some(Event::Delete(pod)))) => {
                    ready_hosts.write().await.remove(&pod.name_any());
                }
                Ok(Ok(None)) => break,
                Ok(Err(error)) => {
                    watcher_ready.store(false, Ordering::Release);
                    warn!(error = %error, "worker pod watch failed; forcing a fresh relist");
                    break;
                }
                Err(_) => {
                    watcher_ready.store(false, Ordering::Release);
                    warn!("worker pod watch made no progress; forcing a fresh relist");
                    break;
                }
            }
        }

        watcher_ready.store(false, Ordering::Release);
        error!("worker pod watch terminated; restarting");
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

fn update_ready_set(hosts: &mut BTreeSet<String>, pod: &Pod) {
    let name = pod.name_any();
    if pod_ready(pod) {
        hosts.insert(name);
    } else {
        hosts.remove(&name);
    }
}

async fn serve(bind: SocketAddr, state: AppState) {
    let app = Router::new()
        .route("/healthz", get(health))
        .route("/readyz", get(ready))
        .route("/metrics", get(metrics))
        .with_state(state);
    match tokio::net::TcpListener::bind(bind).await {
        Ok(listener) => {
            if let Err(error) = axum::serve(listener, app).await {
                error!(error = %error, "metrics server failed");
            }
        }
        Err(error) => error!(error = %error, %bind, "metrics listener failed"),
    }
}

async fn health() -> &'static str {
    "ok\n"
}

async fn ready(State(state): State<AppState>) -> impl IntoResponse {
    if state.watcher_ready.load(Ordering::Acquire) && state.reconcile_ready.load(Ordering::Acquire)
    {
        (StatusCode::OK, "ready\n")
    } else {
        (StatusCode::SERVICE_UNAVAILABLE, "not ready\n")
    }
}

async fn metrics(State(state): State<AppState>) -> impl IntoResponse {
    let mut body = String::new();
    let result = state
        .registry
        .lock()
        .map_err(|_| ())
        .and_then(|registry| encode(&mut body, &registry).map_err(|_| ()));
    if result.is_ok() {
        (StatusCode::OK, body)
    } else {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            "metrics unavailable\n".into(),
        )
    }
}

fn as_i64(value: usize) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use symphony_control_plane::symphony::{Demand, SessionEntry, SymphonyState, WorkerPool};

    use super::*;

    fn state() -> SymphonyState {
        SymphonyState {
            demand: Demand {
                eligible: 0,
                observed_at: Some(Utc::now()),
            },
            worker_pool: WorkerPool {
                configured_hosts: vec![],
                drained_hosts: vec![],
                available_hosts: vec![],
                available_slots: 0,
            },
            running: vec![
                SessionEntry {
                    issue_identifier: Some("A-1".into()),
                    worker_host: Some("symphony-worker-1.workers".into()),
                },
                SessionEntry {
                    issue_identifier: Some("A-2".into()),
                    worker_host: Some("symphony-worker-2.workers".into()),
                },
            ],
            retrying: vec![SessionEntry {
                issue_identifier: Some("A-3".into()),
                worker_host: Some("symphony-worker-3.workers".into()),
            }],
            blocked: vec![],
        }
    }

    #[test]
    fn drain_set_comparison_is_order_independent() {
        assert!(same_hosts(
            &["symphony-worker-2".into(), "symphony-worker-1".into()],
            &["symphony-worker-1".into(), "symphony-worker-2".into()]
        ));
    }

    #[test]
    fn unchanged_drains_still_block_active_scale_down() {
        assert_eq!(
            active_drained_hosts(
                &state(),
                &[
                    "symphony-worker-2.workers".into(),
                    "symphony-worker-3.workers".into()
                ]
            ),
            ["symphony-worker-2.workers", "symphony-worker-3.workers"]
        );
    }
}
