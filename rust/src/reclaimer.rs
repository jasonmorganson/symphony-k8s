use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

use chrono::{DateTime, Utc};
use regex::Regex;
use reqwest::Client;
use serde::Deserialize;
use serde_json::json;
use thiserror::Error;

use crate::symphony::SymphonyState;

const TERMINAL_STATE_TYPES: [&str; 2] = ["completed", "canceled"];
const LINEAR_QUERY_BATCH_SIZE: usize = 50;
const LINEAR_GRAPHQL_ENDPOINT: &str = "https://api.linear.app/graphql";

#[derive(Clone, Debug)]
pub struct ReclaimerConfig {
    pub root: PathBuf,
    pub state_path: PathBuf,
    pub confirmations: u32,
    pub grace_seconds: i64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct LinearIssueState {
    pub state_type: String,
    pub terminal_at: DateTime<Utc>,
}

#[derive(Debug, Error)]
pub enum ReclaimerError {
    #[error("workspace root is invalid: {0}")]
    InvalidRoot(String),
    #[error("workspace path escaped the configured root: {0}")]
    PathEscape(String),
    #[error("workspace path is a symlink: {0}")]
    Symlink(String),
    #[error("reclaimer confirmations must be at least two")]
    InvalidConfirmations,
    #[error("reclaimer grace must be nonnegative")]
    InvalidGrace,
    #[error("filesystem operation failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("reclaimer state is invalid: {0}")]
    State(#[from] serde_json::Error),
    #[error("Linear request failed: {0}")]
    LinearRequest(#[from] reqwest::Error),
    #[error("Linear workspace reclaimer query failed")]
    LinearResponse,
    #[error("Symphony state contains an active session without an issue identifier")]
    InvalidSymphonyState,
}

#[derive(Clone, Debug)]
pub struct WorkspaceReclaimer {
    root: PathBuf,
    state_path: PathBuf,
    confirmations: u32,
    grace_seconds: i64,
    issue_directory: Regex,
}

#[derive(Debug, Deserialize)]
struct LinearGraphQlResponse {
    data: Option<BTreeMap<String, Option<LinearIssue>>>,
    #[serde(default)]
    errors: Vec<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct LinearIssue {
    identifier: String,
    #[serde(rename = "completedAt")]
    completed_at: Option<DateTime<Utc>>,
    #[serde(rename = "canceledAt")]
    canceled_at: Option<DateTime<Utc>>,
    state: LinearState,
}

#[derive(Debug, Deserialize)]
struct LinearState {
    #[serde(rename = "type")]
    state_type: String,
}

impl WorkspaceReclaimer {
    pub fn new(config: ReclaimerConfig) -> Result<Self, ReclaimerError> {
        if config.confirmations < 2 {
            return Err(ReclaimerError::InvalidConfirmations);
        }
        if config.grace_seconds < 0 {
            return Err(ReclaimerError::InvalidGrace);
        }

        let root = config
            .root
            .canonicalize()
            .map_err(|error| ReclaimerError::InvalidRoot(error.to_string()))?;
        if !root.is_dir() {
            return Err(ReclaimerError::InvalidRoot(format!(
                "{} is not a directory",
                root.display()
            )));
        }

        let state_parent = config
            .state_path
            .parent()
            .ok_or_else(|| ReclaimerError::InvalidRoot("state path has no parent".into()))?
            .canonicalize()
            .map_err(|error| ReclaimerError::InvalidRoot(error.to_string()))?;
        if !state_parent.is_dir() {
            return Err(ReclaimerError::InvalidRoot(format!(
                "{} is not a directory",
                state_parent.display()
            )));
        }
        let state_name = config
            .state_path
            .file_name()
            .ok_or_else(|| ReclaimerError::InvalidRoot("state path has no file name".into()))?;

        Ok(Self {
            root,
            state_path: state_parent.join(state_name),
            confirmations: config.confirmations,
            grace_seconds: config.grace_seconds,
            issue_directory: Regex::new(r"^A-[1-9][0-9]*$").expect("static issue regex"),
        })
    }

    pub fn issue_directories(&self) -> Result<BTreeMap<String, PathBuf>, ReclaimerError> {
        let mut directories = BTreeMap::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if !self.issue_directory.is_match(&name) {
                continue;
            }

            let file_type = entry.file_type()?;
            if file_type.is_symlink() {
                return Err(ReclaimerError::Symlink(name));
            }
            if file_type.is_dir() {
                directories.insert(name, entry.path());
            }
        }
        Ok(directories)
    }

    pub fn reclaim(
        &self,
        symphony_state: &SymphonyState,
        linear_states: &BTreeMap<String, LinearIssueState>,
        now: DateTime<Utc>,
    ) -> Result<Vec<String>, ReclaimerError> {
        let directories = self.issue_directories()?;
        self.reclaim_directories(symphony_state, linear_states, directories, now)
    }

    pub fn reclaim_directories(
        &self,
        symphony_state: &SymphonyState,
        linear_states: &BTreeMap<String, LinearIssueState>,
        directories: BTreeMap<String, PathBuf>,
        now: DateTime<Utc>,
    ) -> Result<Vec<String>, ReclaimerError> {
        let active = active_issue_identifiers(symphony_state)?;
        let previous = self.load_observations()?;
        let mut next_observations = BTreeMap::new();
        let mut removed = Vec::new();

        for (identifier, path) in directories {
            let Some(issue) = linear_states.get(&identifier) else {
                continue;
            };
            if active.contains(&identifier)
                || !TERMINAL_STATE_TYPES.contains(&issue.state_type.as_str())
                || now.signed_duration_since(issue.terminal_at).num_seconds() < self.grace_seconds
            {
                continue;
            }

            let count = previous.get(&identifier).copied().unwrap_or_default() + 1;
            next_observations.insert(identifier.clone(), count);
            if count < self.confirmations {
                continue;
            }

            self.remove_workspace(&identifier, &path)?;
            next_observations.remove(&identifier);
            removed.push(identifier);
        }

        if next_observations != previous || !self.state_path.exists() {
            self.save_observations(&next_observations)?;
        }
        Ok(removed)
    }

    fn load_observations(&self) -> Result<BTreeMap<String, u32>, ReclaimerError> {
        self.validate_regular_file_or_missing(&self.state_path)?;
        match fs::read(&self.state_path) {
            Ok(bytes) => Ok(serde_json::from_slice(&bytes)?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(BTreeMap::new()),
            Err(error) => Err(error.into()),
        }
    }

    fn save_observations(
        &self,
        observations: &BTreeMap<String, u32>,
    ) -> Result<(), ReclaimerError> {
        let parent = self
            .state_path
            .parent()
            .ok_or_else(|| ReclaimerError::InvalidRoot("state path has no parent".into()))?;
        fs::create_dir_all(parent)?;
        self.validate_regular_file_or_missing(&self.state_path)?;

        let state_name = self
            .state_path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| ReclaimerError::InvalidRoot("state path has no file name".into()))?;
        let temporary = parent.join(format!(".{state_name}.tmp-{}", std::process::id()));
        self.remove_stale_temporary(&temporary)?;
        let bytes = serde_json::to_vec(observations)?;
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, &self.state_path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    }

    fn validate_regular_file_or_missing(&self, path: &Path) -> Result<(), ReclaimerError> {
        match fs::symlink_metadata(path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                Err(ReclaimerError::Symlink(path.display().to_string()))
            }
            Ok(metadata) if metadata.is_file() => Ok(()),
            Ok(_) => Err(ReclaimerError::InvalidRoot(format!(
                "{} is not a regular file",
                path.display()
            ))),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }

    fn remove_stale_temporary(&self, path: &Path) -> Result<(), ReclaimerError> {
        self.validate_regular_file_or_missing(path)?;
        match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }

    fn remove_workspace(&self, identifier: &str, path: &Path) -> Result<(), ReclaimerError> {
        let metadata = fs::symlink_metadata(path)?;
        if metadata.file_type().is_symlink() {
            return Err(ReclaimerError::Symlink(identifier.into()));
        }

        let resolved = path.canonicalize()?;
        if resolved.parent() != Some(self.root.as_path())
            || resolved.file_name().and_then(|name| name.to_str()) != Some(identifier)
        {
            return Err(ReclaimerError::PathEscape(resolved.display().to_string()));
        }

        let tombstone = self
            .root
            .join(format!(".reclaim-{identifier}-{}", std::process::id()));
        if tombstone.exists() {
            return Err(ReclaimerError::PathEscape(format!(
                "cleanup tombstone already exists: {}",
                tombstone.display()
            )));
        }
        fs::rename(&resolved, &tombstone)?;
        fs::remove_dir_all(&tombstone)?;
        Ok(())
    }
}

pub fn active_issue_identifiers(state: &SymphonyState) -> Result<BTreeSet<String>, ReclaimerError> {
    state
        .running
        .iter()
        .chain(&state.retrying)
        .chain(&state.blocked)
        .map(|entry| {
            entry
                .issue_identifier
                .clone()
                .filter(|identifier| !identifier.trim().is_empty())
                .ok_or(ReclaimerError::InvalidSymphonyState)
        })
        .collect()
}

pub async fn linear_issue_states(
    client: &Client,
    api_key: &str,
    identifiers: impl IntoIterator<Item = String>,
) -> Result<BTreeMap<String, LinearIssueState>, ReclaimerError> {
    linear_issue_states_at(client, api_key, LINEAR_GRAPHQL_ENDPOINT, identifiers).await
}

async fn linear_issue_states_at(
    client: &Client,
    api_key: &str,
    endpoint: &str,
    identifiers: impl IntoIterator<Item = String>,
) -> Result<BTreeMap<String, LinearIssueState>, ReclaimerError> {
    let identifiers = identifiers.into_iter().collect::<BTreeSet<_>>();
    if identifiers.is_empty() {
        return Ok(BTreeMap::new());
    }

    let mut states = BTreeMap::new();
    let identifiers = identifiers.into_iter().collect::<Vec<_>>();
    for batch in identifiers.chunks(LINEAR_QUERY_BATCH_SIZE) {
        let query = linear_query(batch);

        let response = client
            .post(endpoint)
            .header("Authorization", api_key)
            .header("User-Agent", "symphony-workspace-reclaimer")
            .json(&json!({ "query": query }))
            .send()
            .await?
            .error_for_status()?
            .json::<LinearGraphQlResponse>()
            .await?;

        if !response.errors.is_empty() {
            return Err(ReclaimerError::LinearResponse);
        }
        let data = response.data.ok_or(ReclaimerError::LinearResponse)?;
        for issue in data.into_values().flatten() {
            let terminal_at = issue.completed_at.or(issue.canceled_at);
            if let Some(terminal_at) = terminal_at {
                states.insert(
                    issue.identifier,
                    LinearIssueState {
                        state_type: issue.state.state_type,
                        terminal_at,
                    },
                );
            }
        }
    }
    Ok(states)
}

fn linear_query(identifiers: &[String]) -> String {
    let selections = identifiers
        .iter()
        .enumerate()
        .map(|(index, identifier)| {
            format!(
                "i{index}: issue(id: \"{identifier}\") \
                 {{ identifier completedAt canceledAt state {{ type }} }}"
            )
        })
        .collect::<Vec<_>>()
        .join(" ");
    format!("query WorkspaceReclaimer {{ {selections} }}")
}

#[cfg(test)]
mod tests {
    use std::{
        os::unix::fs::symlink,
        sync::{Arc, Mutex},
    };

    use axum::{Json, Router, extract::State, routing::post};
    use chrono::TimeDelta;
    use serde_json::Value;
    use tempfile::TempDir;
    use tokio::net::TcpListener;

    use super::*;
    use crate::symphony::{Demand, SessionEntry, WorkerPool};

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
            running: vec![],
            retrying: vec![],
            blocked: vec![],
        }
    }

    fn fixture() -> (TempDir, WorkspaceReclaimer) {
        let temporary = TempDir::new().unwrap();
        let root = temporary.path().join("workspaces");
        fs::create_dir(&root).unwrap();
        let reclaimer = WorkspaceReclaimer::new(ReclaimerConfig {
            root,
            state_path: temporary.path().join("state.json"),
            confirmations: 2,
            grace_seconds: 3600,
        })
        .unwrap();
        (temporary, reclaimer)
    }

    fn workspace(reclaimer: &WorkspaceReclaimer, identifier: &str) -> PathBuf {
        let path = reclaimer.root.join(identifier);
        fs::create_dir(&path).unwrap();
        fs::write(path.join("evidence"), "kept until safe").unwrap();
        path
    }

    fn terminal(now: DateTime<Utc>) -> LinearIssueState {
        LinearIssueState {
            state_type: "completed".into(),
            terminal_at: now - TimeDelta::hours(2),
        }
    }

    #[test]
    fn requires_two_terminal_observations_before_atomic_removal() {
        let (_temporary, reclaimer) = fixture();
        let now = Utc::now();
        let path = workspace(&reclaimer, "A-218");
        let issues = BTreeMap::from([("A-218".into(), terminal(now))]);

        assert!(
            reclaimer
                .reclaim(&state(), &issues, now)
                .unwrap()
                .is_empty()
        );
        assert!(path.exists());
        assert_eq!(
            reclaimer.reclaim(&state(), &issues, now).unwrap(),
            ["A-218"]
        );
        assert!(!path.exists());
    }

    #[test]
    fn active_sessions_are_never_removed() {
        let (_temporary, reclaimer) = fixture();
        let now = Utc::now();
        for identifier in ["A-1", "A-2", "A-3"] {
            workspace(&reclaimer, identifier);
        }
        let mut active = state();
        active.running = vec![SessionEntry {
            issue_identifier: Some("A-1".into()),
            worker_host: None,
        }];
        active.retrying = vec![SessionEntry {
            issue_identifier: Some("A-2".into()),
            worker_host: None,
        }];
        active.blocked = vec![SessionEntry {
            issue_identifier: Some("A-3".into()),
            worker_host: None,
        }];
        let issues = ["A-1", "A-2", "A-3"]
            .into_iter()
            .map(|identifier| (identifier.into(), terminal(now)))
            .collect();

        assert!(reclaimer.reclaim(&active, &issues, now).unwrap().is_empty());
        assert_eq!(reclaimer.issue_directories().unwrap().len(), 3);
    }

    #[test]
    fn recent_nonterminal_and_unknown_issues_are_preserved() {
        let (_temporary, reclaimer) = fixture();
        let now = Utc::now();
        for identifier in ["A-10", "A-11", "A-12"] {
            workspace(&reclaimer, identifier);
        }
        let issues = BTreeMap::from([
            (
                "A-10".into(),
                LinearIssueState {
                    state_type: "started".into(),
                    terminal_at: now - TimeDelta::hours(2),
                },
            ),
            (
                "A-11".into(),
                LinearIssueState {
                    state_type: "completed".into(),
                    terminal_at: now - TimeDelta::minutes(30),
                },
            ),
        ]);

        assert!(
            reclaimer
                .reclaim(&state(), &issues, now)
                .unwrap()
                .is_empty()
        );
        assert_eq!(reclaimer.issue_directories().unwrap().len(), 3);
    }

    #[test]
    fn symlink_issue_path_fails_closed() {
        let (temporary, reclaimer) = fixture();
        let outside = temporary.path().join("outside");
        fs::create_dir(&outside).unwrap();
        symlink(&outside, reclaimer.root.join("A-20")).unwrap();

        assert!(matches!(
            reclaimer.issue_directories(),
            Err(ReclaimerError::Symlink(identifier)) if identifier == "A-20"
        ));
        assert!(outside.exists());
    }

    #[test]
    fn invalid_persisted_state_fails_closed() {
        let (_temporary, reclaimer) = fixture();
        let now = Utc::now();
        workspace(&reclaimer, "A-21");
        fs::write(&reclaimer.state_path, "{not-json").unwrap();

        assert!(matches!(
            reclaimer.reclaim(
                &state(),
                &BTreeMap::from([("A-21".into(), terminal(now))]),
                now
            ),
            Err(ReclaimerError::State(_))
        ));
        assert!(reclaimer.root.join("A-21").exists());
    }

    #[test]
    fn symlink_state_file_fails_closed() {
        let (temporary, reclaimer) = fixture();
        let outside = temporary.path().join("outside-state.json");
        fs::write(&outside, "{}").unwrap();
        symlink(&outside, &reclaimer.state_path).unwrap();

        assert!(matches!(
            reclaimer.reclaim(&state(), &BTreeMap::new(), Utc::now()),
            Err(ReclaimerError::Symlink(path)) if path.contains("state.json")
        ));
        assert_eq!(fs::read_to_string(outside).unwrap(), "{}");
    }

    #[test]
    fn path_outside_workspace_root_is_rejected() {
        let (temporary, reclaimer) = fixture();
        let outside = temporary.path().join("A-22");
        fs::create_dir(&outside).unwrap();

        assert!(matches!(
            reclaimer.remove_workspace("A-22", &outside),
            Err(ReclaimerError::PathEscape(_))
        ));
        assert!(outside.exists());
    }

    #[test]
    fn uncertain_symphony_session_state_fails_closed() {
        let mut uncertain = state();
        uncertain.running.push(SessionEntry {
            issue_identifier: None,
            worker_host: None,
        });

        assert!(matches!(
            active_issue_identifiers(&uncertain),
            Err(ReclaimerError::InvalidSymphonyState)
        ));
    }

    #[test]
    fn linear_query_aliases_every_identifier() {
        let query = linear_query(
            &(1..=LINEAR_QUERY_BATCH_SIZE)
                .map(|index| format!("A-{index}"))
                .collect::<Vec<_>>(),
        );
        assert!(query.contains("i0: issue(id: \"A-1\")"));
        assert!(query.contains("i49: issue(id: \"A-50\")"));
        assert_eq!(query.matches(": issue(").count(), LINEAR_QUERY_BATCH_SIZE);
    }

    #[tokio::test]
    async fn linear_queries_are_split_at_the_batch_boundary() {
        #[derive(Clone)]
        struct Calls(Arc<Mutex<Vec<usize>>>);

        async fn graphql(State(calls): State<Calls>, Json(payload): Json<Value>) -> Json<Value> {
            let query = payload["query"].as_str().unwrap();
            calls
                .0
                .lock()
                .unwrap()
                .push(query.matches(": issue(").count());
            Json(json!({ "data": {} }))
        }

        let calls = Calls(Arc::new(Mutex::new(Vec::new())));
        let app = Router::new()
            .route("/", post(graphql))
            .with_state(calls.clone());
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        let identifiers = (1..=51).map(|index| format!("A-{index}"));
        let states = linear_issue_states_at(
            &Client::new(),
            "token",
            &format!("http://{address}"),
            identifiers,
        )
        .await
        .unwrap();

        assert!(states.is_empty());
        assert_eq!(*calls.0.lock().unwrap(), [50, 1]);
    }

    #[tokio::test]
    async fn linear_graphql_errors_fail_closed() {
        async fn graphql() -> Json<Value> {
            Json(json!({
                "data": null,
                "errors": [{ "message": "rate limited" }]
            }))
        }

        let app = Router::new().route("/", post(graphql));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        assert!(matches!(
            linear_issue_states_at(
                &Client::new(),
                "token",
                &format!("http://{address}"),
                ["A-1".into()]
            )
            .await,
            Err(ReclaimerError::LinearResponse)
        ));
    }
}
