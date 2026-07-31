use anyhow::{Context, Result, bail};
use std::path::PathBuf;
use symphony_control_plane::session_supervisor::{
    ClientConfig, DaemonConfig, run_client, run_daemon,
};

fn main() -> Result<()> {
    let mut args = std::env::args_os();
    let _program = args.next();
    match args
        .next()
        .and_then(|arg| arg.into_string().ok())
        .as_deref()
    {
        Some("daemon") => {
            let socket = std::env::var_os("SYMPHONY_SESSION_SOCKET")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/run/symphony/session-supervisor.sock"));
            let worker_uid = std::env::var("SYMPHONY_WORKER_UID")
                .unwrap_or_else(|_| "10001".into())
                .parse()
                .context("SYMPHONY_WORKER_UID must be an integer")?;
            let worker_gid = std::env::var("SYMPHONY_WORKER_GID")
                .unwrap_or_else(|_| "10001".into())
                .parse()
                .context("SYMPHONY_WORKER_GID must be an integer")?;
            let mut config = DaemonConfig::production(socket, worker_uid, worker_gid);
            if let Some(root) = std::env::var_os("SYMPHONY_WORKSPACE_ROOT") {
                config.workspace_root = PathBuf::from(root);
            }
            if let Ok(value) = std::env::var("SYMPHONY_SESSION_METADATA_TIMEOUT_MS") {
                config.metadata_timeout = std::time::Duration::from_millis(
                    value
                        .parse()
                        .context("SYMPHONY_SESSION_METADATA_TIMEOUT_MS must be an integer")?,
                );
            }
            run_daemon(config)
        }
        Some("client") => {
            if args.next().as_deref() != Some(std::ffi::OsStr::new("--")) {
                bail!("usage: symphony-session-supervisor client -- COMMAND [ARG ...]");
            }
            let command: Vec<_> = args.collect();
            if command.is_empty() {
                bail!("session command is required");
            }
            let socket = std::env::var_os("SYMPHONY_SESSION_SOCKET")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/run/symphony/session-supervisor.sock"));
            let code = run_client(ClientConfig::production(socket), &command)?;
            std::process::exit(code);
        }
        _ => bail!("usage: symphony-session-supervisor <daemon|client> ..."),
    }
}
