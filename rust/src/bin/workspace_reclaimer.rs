use std::{
    env,
    net::SocketAddr,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use anyhow::{Context, Result, bail};
use axum::{Router, extract::State, http::StatusCode, response::IntoResponse, routing::get};
use chrono::Utc;
use prometheus_client::{
    encoding::text::encode,
    metrics::{counter::Counter, gauge::Gauge},
    registry::Registry,
};
use symphony_control_plane::{
    env::{i64 as env_i64, string as env_string, u32 as env_u32, u64 as env_u64},
    reclaimer::{ReclaimerConfig, WorkspaceReclaimer},
    symphony::SymphonyClient,
};
use tokio::time::{MissedTickBehavior, interval};
use tracing::{error, info};

#[derive(Clone)]
struct AppState {
    registry: Arc<Mutex<Registry>>,
    ready: Arc<AtomicBool>,
}

#[derive(Clone)]
struct Metrics {
    observed: Gauge,
    removed: Counter,
    reconciliations: Counter,
    failures: Counter,
}

impl Metrics {
    fn register(registry: &mut Registry) -> Self {
        let metrics = Self {
            observed: Gauge::default(),
            removed: Counter::default(),
            reconciliations: Counter::default(),
            failures: Counter::default(),
        };
        registry.register(
            "symphony_workspace_reclaimer_observed",
            "Issue workspace directories observed.",
            metrics.observed.clone(),
        );
        registry.register(
            "symphony_workspace_reclaimer_removed_total",
            "Terminal workspaces removed.",
            metrics.removed.clone(),
        );
        registry.register(
            "symphony_workspace_reclaimer_reconciliations_total",
            "Successful reclaimer reconciliations.",
            metrics.reconciliations.clone(),
        );
        registry.register(
            "symphony_workspace_reclaimer_failures_total",
            "Failed reclaimer reconciliations.",
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
                .unwrap_or_else(|_| "symphony_workspace_reclaimer=info,warn".into()),
        )
        .init();

    let interval_seconds = env_u64("WORKSPACE_RECLAIMER_INTERVAL_SECONDS", 600)?;
    if interval_seconds < 60 {
        bail!("workspace reclaimer interval must be at least 60 seconds");
    }
    let control_token =
        env::var("SYMPHONY_WORKER_DRAIN_TOKEN").context("missing SYMPHONY_WORKER_DRAIN_TOKEN")?;
    let reclaimer = WorkspaceReclaimer::new(ReclaimerConfig {
        root: PathBuf::from(env_string("WORKSPACE_ROOT", "/srv/symphony/workspaces")),
        state_path: PathBuf::from(env_string(
            "WORKSPACE_RECLAIMER_STATE_PATH",
            "/srv/worker-data/.workspace-reclaimer-state.json",
        )),
        confirmations: env_u32("WORKSPACE_RECLAIMER_CONFIRMATIONS", 2)?,
        grace_seconds: env_i64("WORKSPACE_RECLAIMER_GRACE_SECONDS", 3600)?,
    })?;
    let symphony = SymphonyClient::new(
        env_string(
            "SYMPHONY_STATE_URL",
            "http://symphony-orchestrator:4000/api/v1/state",
        ),
        env_string(
            "SYMPHONY_DRAINS_URL",
            "http://symphony-orchestrator:4000/api/v1/worker-drains",
        ),
        control_token,
    )?;

    let mut registry = Registry::default();
    let metrics = Metrics::register(&mut registry);
    let ready = Arc::new(AtomicBool::new(false));
    let state = AppState {
        registry: Arc::new(Mutex::new(registry)),
        ready: ready.clone(),
    };
    let bind = env_string("METRICS_BIND", "0.0.0.0:8081")
        .parse()
        .context("invalid METRICS_BIND")?;
    tokio::spawn(serve(bind, state));

    let mut ticker = interval(Duration::from_secs(interval_seconds));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        ticker.tick().await;
        match reclaim_once(&reclaimer, &symphony, &metrics).await {
            Ok(removed) => {
                ready.store(true, Ordering::Release);
                metrics.reconciliations.inc();
                metrics.removed.inc_by(removed.len() as u64);
                info!(removed = ?removed, "workspace reclamation completed");
            }
            Err(error) => {
                ready.store(false, Ordering::Release);
                metrics.failures.inc();
                error!(error = %error, "workspace reclamation failed closed");
            }
        }
    }
}

async fn reclaim_once(
    reclaimer: &WorkspaceReclaimer,
    symphony: &SymphonyClient,
    metrics: &Metrics,
) -> Result<Vec<String>> {
    symphony.state().await?;
    let directories = reclaimer.issue_directories()?;
    metrics
        .observed
        .set(i64::try_from(directories.len()).unwrap_or(i64::MAX));
    let identifiers = directories.keys().cloned().collect::<Vec<_>>();
    let terminal_states = symphony.terminal_issue_states(&identifiers).await?;
    let final_state = symphony.state().await?;
    Ok(reclaimer.reclaim_directories(&final_state, &terminal_states, directories, Utc::now())?)
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
    if state.ready.load(Ordering::Acquire) {
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
