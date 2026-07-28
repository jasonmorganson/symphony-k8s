use std::time::Duration;

use chrono::{DateTime, Utc};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Clone, Debug, Deserialize)]
pub struct SymphonyState {
    pub demand: Demand,
    pub worker_pool: WorkerPool,
    pub running: Vec<SessionEntry>,
    pub retrying: Vec<SessionEntry>,
    pub blocked: Vec<SessionEntry>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Demand {
    pub eligible: u32,
    pub observed_at: Option<DateTime<Utc>>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct WorkerPool {
    pub configured_hosts: Vec<String>,
    pub drained_hosts: Vec<String>,
    pub available_hosts: Vec<String>,
    pub available_slots: u32,
}

#[derive(Clone, Debug, Deserialize)]
pub struct SessionEntry {
    pub issue_identifier: Option<String>,
    pub worker_host: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct DrainResponse {
    pub configured_hosts: Vec<String>,
    pub drained_hosts: Vec<String>,
    pub active_drained_hosts: Vec<String>,
}

#[derive(Serialize)]
struct DrainRequest<'a> {
    drained_worker_hosts: &'a [String],
}

#[derive(Debug, Error)]
pub enum SymphonyError {
    #[error("Symphony request failed: {0}")]
    Request(#[from] reqwest::Error),
    #[error("Symphony returned HTTP {0}")]
    Http(StatusCode),
    #[error("Symphony drain acknowledgement did not match the requested hosts")]
    DrainMismatch,
}

#[derive(Clone)]
pub struct SymphonyStateClient {
    http: Client,
    state_url: String,
}

impl SymphonyStateClient {
    pub fn new(state_url: String) -> Result<Self, SymphonyError> {
        Ok(Self {
            http: Client::builder().timeout(Duration::from_secs(15)).build()?,
            state_url,
        })
    }

    pub async fn state(&self) -> Result<SymphonyState, SymphonyError> {
        let response = self.http.get(&self.state_url).send().await?;
        if !response.status().is_success() {
            return Err(SymphonyError::Http(response.status()));
        }
        Ok(response.json().await?)
    }
}

#[derive(Clone)]
pub struct SymphonyClient {
    state: SymphonyStateClient,
    drains_url: String,
    drain_token: String,
}

impl SymphonyClient {
    pub fn new(
        state_url: String,
        drains_url: String,
        drain_token: String,
    ) -> Result<Self, SymphonyError> {
        Ok(Self {
            state: SymphonyStateClient::new(state_url)?,
            drains_url,
            drain_token,
        })
    }

    pub async fn state(&self) -> Result<SymphonyState, SymphonyError> {
        self.state.state().await
    }

    pub async fn set_drains(&self, hosts: &[String]) -> Result<DrainResponse, SymphonyError> {
        let response = self
            .state
            .http
            .put(&self.drains_url)
            .bearer_auth(&self.drain_token)
            .json(&DrainRequest {
                drained_worker_hosts: hosts,
            })
            .send()
            .await?;

        if !response.status().is_success() {
            return Err(SymphonyError::Http(response.status()));
        }

        let acknowledgement: DrainResponse = response.json().await?;
        let mut expected = hosts.to_vec();
        expected.sort();
        if acknowledgement.drained_hosts != expected {
            return Err(SymphonyError::DrainMismatch);
        }
        Ok(acknowledgement)
    }
}

#[cfg(test)]
mod tests {
    use axum::{
        Json, Router,
        extract::State,
        http::{HeaderMap, StatusCode},
        routing::{get, put},
    };
    use serde_json::{Value, json};
    use tokio::net::TcpListener;

    use super::*;

    #[derive(Clone)]
    struct FakeState {
        token: String,
    }

    #[tokio::test]
    async fn client_reads_state_and_replaces_exact_drains() {
        let token = "d".repeat(32);
        let app = Router::new()
            .route("/api/v1/state", get(fake_state))
            .route("/api/v1/worker-drains", put(fake_drains))
            .with_state(FakeState {
                token: token.clone(),
            });
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        let client = SymphonyClient::new(
            format!("http://{address}/api/v1/state"),
            format!("http://{address}/api/v1/worker-drains"),
            token,
        )
        .unwrap();
        let state = client.state().await.unwrap();
        assert_eq!(state.demand.eligible, 3);
        assert_eq!(state.demand.observed_at, None);

        let acknowledgement = client
            .set_drains(&["symphony-worker-2".into()])
            .await
            .unwrap();
        assert_eq!(
            acknowledgement.drained_hosts,
            ["symphony-worker-2".to_string()]
        );
    }

    async fn fake_state() -> Json<Value> {
        Json(json!({
            "demand": {
                "eligible": 3,
                "observed_at": null
            },
            "worker_pool": {
                "configured_hosts": ["symphony-worker-0", "symphony-worker-1", "symphony-worker-2"],
                "drained_hosts": ["symphony-worker-2"],
                "available_hosts": ["symphony-worker-0", "symphony-worker-1"],
                "available_slots": 2
            },
            "running": [],
            "retrying": [],
            "blocked": []
        }))
    }

    async fn fake_drains(
        State(state): State<FakeState>,
        headers: HeaderMap,
        Json(body): Json<Value>,
    ) -> Result<Json<Value>, StatusCode> {
        if headers
            .get("authorization")
            .and_then(|value| value.to_str().ok())
            != Some(&format!("Bearer {}", state.token))
        {
            return Err(StatusCode::UNAUTHORIZED);
        }
        let drains = body
            .get("drained_worker_hosts")
            .cloned()
            .ok_or(StatusCode::UNPROCESSABLE_ENTITY)?;
        Ok(Json(json!({
            "configured_hosts": ["symphony-worker-0", "symphony-worker-1", "symphony-worker-2"],
            "drained_hosts": drains,
            "active_drained_hosts": []
        })))
    }
}
