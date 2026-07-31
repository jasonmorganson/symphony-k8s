#![cfg(target_os = "linux")]

use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

struct Daemon(Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_symphony-session-supervisor")
}

fn start_daemon(socket: &std::path::Path) -> Daemon {
    let child = Command::new(binary())
        .arg("daemon")
        .env("SYMPHONY_SESSION_SOCKET", socket)
        .env(
            "SYMPHONY_WORKER_UID",
            unsafe { libc::geteuid() }.to_string(),
        )
        .env(
            "SYMPHONY_WORKER_GID",
            unsafe { libc::getegid() }.to_string(),
        )
        .env("SYMPHONY_WORKSPACE_ROOT", std::env::current_dir().unwrap())
        .env("SYMPHONY_SESSION_METADATA_TIMEOUT_MS", "150")
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() {
        assert!(Instant::now() < deadline, "daemon socket did not appear");
        thread::sleep(Duration::from_millis(10));
    }
    Daemon(child)
}

fn client(socket: &std::path::Path, script: &str) -> Child {
    Command::new(binary())
        .args(["client", "--", "sh", "-c", script])
        .env("SYMPHONY_SESSION_SOCKET", socket)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}

#[test]
fn daemon_owns_the_lock_and_reclaims_a_disconnected_session_before_reuse() {
    let temporary = tempfile::tempdir().unwrap();
    let socket = temporary.path().join("supervisor.sock");
    let _daemon = start_daemon(&socket);
    assert_eq!(
        fs::metadata(&socket).unwrap().permissions().mode() & 0o777,
        0o660
    );

    let mut first = client(
        &socket,
        "trap '' TERM; setsid sh -c 'trap \"\" TERM; sleep 60' & while :; do sh -c true; done & wait",
    );
    thread::sleep(Duration::from_millis(150));
    let mut collision = client(&socket, "true");
    assert!(
        !collision.wait().unwrap().success(),
        "overlapping owner was admitted"
    );

    first.kill().unwrap();
    first.wait().unwrap();
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        let mut replacement = client(&socket, "true");
        if replacement.wait().unwrap().success() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "worker lock was not released after verified cleanup"
        );
        thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn normal_completion_is_acknowledged_and_tracker_secrets_never_reach_the_child() {
    let temporary = tempfile::tempdir().unwrap();
    let socket = temporary.path().join("supervisor.sock");
    let _daemon = start_daemon(&socket);
    let status = Command::new(binary())
        .args([
            "client",
            "--",
            "sh",
            "-c",
            r#"
              test -z "${LINEAR_API_KEY:-}"
              for process in /proc/[0-9]*; do
                if tr '\0' ' ' <"$process/cmdline" 2>/dev/null | grep -q 'symphony-session-supervisor client'; then
                  if tr '\0' '\n' <"$process/environ" 2>/dev/null | grep -q '^LINEAR_API_KEY='; then
                    exit 1
                  fi
                fi
              done
            "#,
        ])
        .env("SYMPHONY_SESSION_SOCKET", &socket)
        .env("LINEAR_API_KEY", "must-not-leak")
        .status()
        .unwrap();
    assert!(status.success());
}

#[test]
fn malformed_socket_path_is_never_replaced() {
    let temporary = tempfile::tempdir().unwrap();
    let socket = temporary.path().join("supervisor.sock");
    fs::write(&socket, "owned by someone else").unwrap();
    let status = Command::new(binary())
        .arg("daemon")
        .env("SYMPHONY_SESSION_SOCKET", &socket)
        .env(
            "SYMPHONY_WORKER_UID",
            unsafe { libc::geteuid() }.to_string(),
        )
        .env(
            "SYMPHONY_WORKER_GID",
            unsafe { libc::getegid() }.to_string(),
        )
        .status()
        .unwrap();
    assert!(!status.success());
    assert_eq!(fs::read_to_string(socket).unwrap(), "owned by someone else");
}

#[test]
fn incomplete_claim_metadata_makes_the_daemon_unhealthy() {
    let temporary = tempfile::tempdir().unwrap();
    let socket = temporary.path().join("supervisor.sock");
    let mut daemon = start_daemon(&socket);
    let stream = UnixStream::connect(&socket).unwrap();
    let mut response = String::new();
    BufReader::new(stream).read_line(&mut response).unwrap();
    assert_eq!(response, "OK\n");
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Some(status) = daemon.0.try_wait().unwrap() {
            assert!(!status.success());
            break;
        }
        assert!(
            Instant::now() < deadline,
            "uncertain claim left a Ready daemon alive"
        );
        thread::sleep(Duration::from_millis(25));
    }
}
