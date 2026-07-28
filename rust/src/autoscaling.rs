use std::collections::BTreeSet;

use chrono::{DateTime, Utc};
use serde::Serialize;
use thiserror::Error;

use crate::symphony::SymphonyState;

const MAX_CLOCK_SKEW_SECONDS: i64 = 30;

#[derive(Clone, Debug)]
pub struct AutoscalerConfig {
    pub minimum: u32,
    pub maximum: u32,
    pub agents_per_worker: u32,
    pub demand_max_age_seconds: i64,
    pub statefulset: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ReconcilePlan {
    pub desired: u32,
    pub active_floor: u32,
    pub drains: Vec<String>,
    pub scale_to: Option<u32>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PlanError {
    #[error("Symphony demand observation is stale")]
    StaleDemand,
    #[error("Symphony demand has not been observed")]
    UnobservedDemand,
    #[error("Symphony demand observation is too far in the future")]
    FutureDemand,
    #[error("worker host configuration does not match StatefulSet ordinals")]
    InvalidWorkerHosts,
    #[error("configured worker capacity is below the autoscaler maximum")]
    InsufficientWorkerHosts,
    #[error("Symphony state is malformed")]
    MalformedState,
}

pub fn desired_workers(eligible: u32, agents_per_worker: u32, minimum: u32, maximum: u32) -> u32 {
    let agents_per_worker = agents_per_worker.max(1);
    let demand = eligible.div_ceil(agents_per_worker);
    demand.clamp(minimum, maximum)
}

pub fn reconcile_plan(
    state: &SymphonyState,
    current: u32,
    ready_hosts: &BTreeSet<String>,
    now: DateTime<Utc>,
    config: &AutoscalerConfig,
) -> Result<ReconcilePlan, PlanError> {
    let observed_at = state
        .demand
        .observed_at
        .ok_or(PlanError::UnobservedDemand)?;
    let demand_age = now.signed_duration_since(observed_at).num_seconds();
    if demand_age > config.demand_max_age_seconds {
        return Err(PlanError::StaleDemand);
    }
    if demand_age < -MAX_CLOCK_SKEW_SECONDS {
        return Err(PlanError::FutureDemand);
    }

    if state.worker_pool.configured_hosts.len() < config.maximum as usize {
        return Err(PlanError::InsufficientWorkerHosts);
    }

    validate_hosts(&state.worker_pool.configured_hosts, &config.statefulset)?;
    if current as usize > state.worker_pool.configured_hosts.len() {
        return Err(PlanError::MalformedState);
    }

    let active_floor = active_floor(state, config)?;
    let active_demand = u32::try_from(state.running.len())
        .ok()
        .and_then(|running| {
            u32::try_from(state.retrying.len())
                .ok()
                .and_then(|retrying| running.checked_add(retrying))
        })
        .and_then(|active| active.checked_add(state.demand.eligible))
        .ok_or(PlanError::MalformedState)?;
    let desired = desired_workers(
        active_demand,
        config.agents_per_worker,
        config.minimum,
        config.maximum,
    )
    .max(active_floor);

    let active_limit = desired.min(current) as usize;
    let drains = state
        .worker_pool
        .configured_hosts
        .iter()
        .enumerate()
        .filter(|(ordinal, host)| {
            *ordinal >= active_limit || !ready_hosts.contains(host_short_name(host))
        })
        .map(|(_, host)| host.clone())
        .collect();
    let scale_to = (desired != current).then_some(desired);

    Ok(ReconcilePlan {
        desired,
        active_floor,
        drains,
        scale_to,
    })
}

fn active_floor(state: &SymphonyState, config: &AutoscalerConfig) -> Result<u32, PlanError> {
    let configured_hosts = state
        .worker_pool
        .configured_hosts
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();

    state.running.iter().try_fold(0, |floor, host| {
        let host = host
            .worker_host
            .as_deref()
            .ok_or(PlanError::MalformedState)?;
        if !configured_hosts.contains(host) {
            return Err(PlanError::MalformedState);
        }
        let ordinal = host_ordinal(host, &config.statefulset)?;
        let host_floor = ordinal.checked_add(1).ok_or(PlanError::MalformedState)?;
        if host_floor > config.maximum {
            return Err(PlanError::MalformedState);
        }
        Ok(floor.max(host_floor))
    })
}

fn validate_hosts(hosts: &[String], statefulset: &str) -> Result<(), PlanError> {
    for (expected, host) in hosts.iter().enumerate() {
        if host_ordinal(host, statefulset)? != expected as u32 {
            return Err(PlanError::InvalidWorkerHosts);
        }
    }
    Ok(())
}

fn host_ordinal(host: &str, statefulset: &str) -> Result<u32, PlanError> {
    let short = host_short_name(host);
    let prefix = format!("{statefulset}-");
    short
        .strip_prefix(&prefix)
        .and_then(|value| value.parse::<u32>().ok())
        .ok_or(PlanError::InvalidWorkerHosts)
}

fn host_short_name(host: &str) -> &str {
    host.split('.').next().unwrap_or(host)
}

#[cfg(test)]
mod tests {
    use chrono::TimeDelta;

    use super::*;
    use crate::symphony::{Demand, WorkerPool};

    fn state(eligible: u32) -> SymphonyState {
        SymphonyState {
            demand: Demand {
                eligible,
                observed_at: Some(Utc::now()),
            },
            worker_pool: WorkerPool {
                configured_hosts: (0..10)
                    .map(|ordinal| format!("symphony-worker-{ordinal}.workers"))
                    .collect(),
                drained_hosts: vec![],
                available_hosts: vec![],
                available_slots: 0,
            },
            running: vec![],
            retrying: vec![],
            blocked: vec![],
        }
    }

    fn config() -> AutoscalerConfig {
        AutoscalerConfig {
            minimum: 0,
            maximum: 10,
            agents_per_worker: 1,
            demand_max_age_seconds: 300,
            statefulset: "symphony-worker".into(),
        }
    }

    #[test]
    fn desired_capacity_clamps_and_rounds_up() {
        assert_eq!(desired_workers(0, 2, 0, 10), 0);
        assert_eq!(desired_workers(3, 2, 0, 10), 2);
        assert_eq!(desired_workers(99, 1, 0, 10), 10);
    }

    #[test]
    fn scale_up_keeps_unready_and_future_workers_drained() {
        let ready = ["symphony-worker-0".into()].into_iter().collect();
        let plan = reconcile_plan(&state(3), 1, &ready, Utc::now(), &config()).unwrap();
        assert_eq!(plan.scale_to, Some(3));
        assert_eq!(plan.drains.first().unwrap(), "symphony-worker-1.workers");
    }

    #[test]
    fn pending_work_scales_beyond_running_sessions() {
        let mut state = state(1);
        state.running.push(crate::symphony::SessionEntry {
            issue_identifier: Some("A-1".into()),
            worker_host: Some("symphony-worker-0.workers".into()),
        });
        let ready = ["symphony-worker-0".into()].into_iter().collect();
        let plan = reconcile_plan(&state, 1, &ready, Utc::now(), &config()).unwrap();
        assert_eq!(plan.active_floor, 1);
        assert_eq!(plan.desired, 2);
        assert_eq!(plan.scale_to, Some(2));
    }

    #[test]
    fn retrying_work_retains_capacity() {
        let mut state = state(0);
        state.retrying.push(crate::symphony::SessionEntry {
            issue_identifier: Some("A-1".into()),
            worker_host: None,
        });
        let plan = reconcile_plan(&state, 0, &BTreeSet::new(), Utc::now(), &config()).unwrap();
        assert_eq!(plan.desired, 1);
        assert_eq!(plan.scale_to, Some(1));
    }

    #[test]
    fn scale_down_drains_trailing_workers_first() {
        let ready = (0..5).map(|i| format!("symphony-worker-{i}")).collect();
        let plan = reconcile_plan(&state(2), 5, &ready, Utc::now(), &config()).unwrap();
        assert_eq!(plan.scale_to, Some(2));
        assert_eq!(plan.drains.len(), 8);
        assert_eq!(plan.drains.first().unwrap(), "symphony-worker-2.workers");
    }

    #[test]
    fn partial_readiness_keeps_unready_current_workers_drained() {
        let ready = ["symphony-worker-0".into()].into_iter().collect();
        let plan = reconcile_plan(&state(3), 3, &ready, Utc::now(), &config()).unwrap();
        assert_eq!(plan.scale_to, None);
        assert_eq!(plan.drains.first().unwrap(), "symphony-worker-1.workers");
    }

    #[test]
    fn unready_worker_does_not_block_later_ready_worker() {
        let ready = ["symphony-worker-0".into(), "symphony-worker-2".into()]
            .into_iter()
            .collect();
        let plan = reconcile_plan(&state(3), 3, &ready, Utc::now(), &config()).unwrap();
        assert!(plan.drains.contains(&"symphony-worker-1.workers".into()));
        assert!(!plan.drains.contains(&"symphony-worker-2.workers".into()));
    }

    #[test]
    fn repeated_reconciliation_is_idempotent() {
        let ready = (0..3).map(|i| format!("symphony-worker-{i}")).collect();
        let first = reconcile_plan(&state(3), 3, &ready, Utc::now(), &config()).unwrap();
        let second = reconcile_plan(&state(3), 3, &ready, Utc::now(), &config()).unwrap();
        assert_eq!(first, second);
        assert_eq!(first.scale_to, None);
        assert_eq!(first.drains.len(), 7);
    }

    #[test]
    fn active_high_ordinal_sets_a_safe_floor() {
        let mut state = state(0);
        state.running.push(crate::symphony::SessionEntry {
            issue_identifier: Some("A-1".into()),
            worker_host: Some("symphony-worker-7.workers".into()),
        });
        let ready = BTreeSet::new();
        let plan = reconcile_plan(&state, 8, &ready, Utc::now(), &config()).unwrap();
        assert_eq!(plan.active_floor, 8);
        assert_eq!(plan.desired, 8);
    }

    #[test]
    fn stale_demand_fails_closed() {
        let mut state = state(0);
        state.demand.observed_at = Some(Utc::now() - TimeDelta::seconds(301));
        assert_eq!(
            reconcile_plan(&state, 5, &BTreeSet::new(), Utc::now(), &config()),
            Err(PlanError::StaleDemand)
        );
    }

    #[test]
    fn future_demand_beyond_clock_skew_fails_closed() {
        let mut state = state(3);
        let now = Utc::now();
        state.demand.observed_at = Some(now + TimeDelta::seconds(MAX_CLOCK_SKEW_SECONDS + 1));
        assert_eq!(
            reconcile_plan(&state, 3, &BTreeSet::new(), now, &config()),
            Err(PlanError::FutureDemand)
        );
    }

    #[test]
    fn active_session_without_worker_identity_fails_closed() {
        let mut state = state(0);
        state.running.push(crate::symphony::SessionEntry {
            issue_identifier: Some("A-1".into()),
            worker_host: None,
        });
        assert_eq!(
            reconcile_plan(&state, 3, &BTreeSet::new(), Utc::now(), &config()),
            Err(PlanError::MalformedState)
        );
    }

    #[test]
    fn unobserved_demand_fails_closed() {
        let mut state = state(0);
        state.demand.observed_at = None;
        assert_eq!(
            reconcile_plan(&state, 3, &BTreeSet::new(), Utc::now(), &config()),
            Err(PlanError::UnobservedDemand)
        );
    }

    #[test]
    fn active_session_on_unconfigured_ordinal_fails_closed() {
        let mut state = state(0);
        state.running.push(crate::symphony::SessionEntry {
            issue_identifier: Some("A-1".into()),
            worker_host: Some("symphony-worker-10.workers".into()),
        });
        assert_eq!(
            reconcile_plan(&state, 3, &BTreeSet::new(), Utc::now(), &config()),
            Err(PlanError::MalformedState)
        );
    }

    #[test]
    fn active_session_with_overflowing_ordinal_fails_closed() {
        let mut state = state(0);
        state
            .worker_pool
            .configured_hosts
            .push(format!("symphony-worker-{}.workers", u32::MAX));
        state.running.push(crate::symphony::SessionEntry {
            issue_identifier: Some("A-1".into()),
            worker_host: Some(format!("symphony-worker-{}.workers", u32::MAX)),
        });
        assert_eq!(
            reconcile_plan(&state, 3, &BTreeSet::new(), Utc::now(), &config()),
            Err(PlanError::InvalidWorkerHosts)
        );
    }
}
