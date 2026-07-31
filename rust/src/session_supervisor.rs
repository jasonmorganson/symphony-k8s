//! Root-owned, crash-safe ownership for one remote task process tree per worker.
//!
//! The daemon, not the agent UID, owns admission and launches every task-scoped
//! command. Linux subreaper adoption makes daemonized/`setsid` descendants
//! remain daemon descendants, so disconnect cleanup cannot be escaped by
//! changing process groups or sessions.

use anyhow::{Context, Result, anyhow, bail};
use nix::sys::socket::{ControlMessage, ControlMessageOwned, MsgFlags, recvmsg, sendmsg};
use std::collections::{HashMap, HashSet};
use std::ffi::{OsStr, OsString};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, IoSlice, IoSliceMut, Read, Write};
#[cfg(target_os = "linux")]
use std::os::fd::OwnedFd;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const TRACKER_SECRETS: &[&[u8]] = &[b"LINEAR_API_KEY", b"LINEAR_TOKEN", b"TRACKER_TOKEN"];
const MAX_ARGUMENTS: usize = 4_096;
const MAX_ARGUMENT_BYTES: usize = 1024 * 1024;
const MAX_COMMAND_BYTES: usize = 1024 * 1024;
const SANITIZED_CLIENT_ENV: &str = "SYMPHONY_SESSION_CLIENT_SANITIZED";

#[derive(Clone, Debug)]
pub struct DaemonConfig {
    pub socket: PathBuf,
    pub workspace_root: PathBuf,
    pub worker_uid: u32,
    pub worker_gid: u32,
    pub metadata_timeout: Duration,
    pub term_grace: Duration,
    pub kill_grace: Duration,
}

impl DaemonConfig {
    pub fn production(socket: PathBuf, worker_uid: u32, worker_gid: u32) -> Self {
        Self {
            socket,
            workspace_root: PathBuf::from("/srv/symphony/workspaces"),
            worker_uid,
            worker_gid,
            metadata_timeout: Duration::from_secs(10),
            term_grace: Duration::from_secs(5),
            kill_grace: Duration::from_secs(5),
        }
    }
}

#[derive(Clone, Debug)]
pub struct ClientConfig {
    pub socket: PathBuf,
    pub handshake_timeout: Duration,
    pub completion_timeout: Duration,
}

impl ClientConfig {
    pub fn production(socket: PathBuf) -> Self {
        Self {
            socket,
            handshake_timeout: Duration::from_secs(10),
            completion_timeout: Duration::from_secs(24 * 60 * 60),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ActiveSession {
    owner_pid: i32,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct ProcessIdentity {
    pid: i32,
    start_time: u64,
}

pub fn run_daemon(config: DaemonConfig) -> Result<()> {
    become_subreaper()?;
    prepare_socket(&config)?;
    let listener = UnixListener::bind(&config.socket)
        .with_context(|| format!("bind {}", config.socket.display()))?;
    fs::set_permissions(&config.socket, fs::Permissions::from_mode(0o660))?;
    chown_socket(&config.socket, config.worker_gid)?;
    let active = Arc::new(Mutex::new(None));

    for connection in listener.incoming() {
        let stream = connection.context("accept supervisor client")?;
        let config = config.clone();
        let active = Arc::clone(&active);
        thread::spawn(move || {
            if let Err(error) = serve_client(stream, &config, &active) {
                eprintln!("session supervisor client failed: {error:#}");
            }
        });
    }
    Ok(())
}

fn prepare_socket(config: &DaemonConfig) -> Result<()> {
    let parent = config.socket.parent().context("socket requires a parent")?;
    fs::create_dir_all(parent)?;
    let metadata = fs::symlink_metadata(parent)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        bail!("supervisor socket parent must be a real directory");
    }
    if let Ok(metadata) = fs::symlink_metadata(&config.socket) {
        if !metadata.file_type().is_socket() || metadata.file_type().is_symlink() {
            bail!("refusing to replace non-socket supervisor path");
        }
        fs::remove_file(&config.socket)?;
    }
    Ok(())
}

fn serve_client(
    mut stream: UnixStream,
    config: &DaemonConfig,
    active: &Arc<Mutex<Option<ActiveSession>>>,
) -> Result<()> {
    let (owner_pid, owner_uid) = peer_credentials(&stream)?;
    if owner_uid != config.worker_uid {
        stream.write_all(b"DENIED\n")?;
        bail!(
            "client uid {owner_uid} is not worker uid {}",
            config.worker_uid
        );
    }
    let owner = ActiveSession { owner_pid };
    if !claim_active(active, owner)? {
        stream.write_all(b"BUSY\n")?;
        return Ok(());
    }
    acknowledge_claim(&mut stream, active, owner)?;

    let result = run_owned_command(&mut stream, config, owner_pid);
    match result {
        Ok(code) => {
            release_active(active, owner)?;
            writeln!(stream, "EXIT {code}")?;
            Ok(())
        }
        Err(error) => {
            let _ = stream.write_all(b"FAILED\n");
            // Any uncertain process ownership makes this worker unsafe. Exiting
            // the daemon removes readiness and lets the pod boundary recover it.
            eprintln!("fatal session cleanup failure: {error:#}");
            std::process::exit(70);
        }
    }
}

fn acknowledge_claim(
    stream: &mut UnixStream,
    active: &Arc<Mutex<Option<ActiveSession>>>,
    owner: ActiveSession,
) -> Result<()> {
    if let Err(error) = stream.write_all(b"OK\n") {
        // No command metadata or child exists yet, so this claim can be
        // released locally without entering uncertain process cleanup.
        release_active(active, owner)?;
        return Err(error.into());
    }
    Ok(())
}

fn run_owned_command(
    stream: &mut UnixStream,
    config: &DaemonConfig,
    owner_pid: i32,
) -> Result<i32> {
    stream.set_read_timeout(Some(config.metadata_timeout))?;
    let stdio = receive_stdio(stream)?;
    let command = read_command(stream)?;
    let cwd = read_peer_cwd(owner_pid, &config.workspace_root)?;
    let environment = read_peer_environment(owner_pid)?;
    let mut child = spawn_owned_command(command, cwd, environment, stdio, config)?;
    stream.set_read_timeout(None)?;
    stream.set_nonblocking(true)?;

    let mut probe = [0_u8; 1];
    loop {
        if let Some(status) = child.try_wait().context("wait for supervised command")? {
            let code = status.code().unwrap_or(1);
            verify_cleanup(&mut child, config)?;
            return Ok(code);
        }
        match stream.read(&mut probe) {
            Ok(0) => {
                break;
            }
            Ok(_) => bail!("unexpected client data while command was active"),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(error) => return Err(error.into()),
        }
        thread::sleep(Duration::from_millis(50));
    }
    verify_cleanup(&mut child, config)?;
    Ok(255)
}

fn spawn_owned_command(
    command: Vec<OsString>,
    cwd: PathBuf,
    environment: Vec<(OsString, OsString)>,
    stdio: [File; 3],
    config: &DaemonConfig,
) -> Result<Child> {
    let [stdin, stdout, stderr] = stdio;
    let mut child = Command::new(&command[0]);
    child
        .args(&command[1..])
        .current_dir(cwd)
        .env_clear()
        .envs(environment)
        .stdin(Stdio::from(stdin))
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr));
    let worker_uid = config.worker_uid;
    let worker_gid = config.worker_gid;
    unsafe {
        child.pre_exec(move || {
            if libc::geteuid() == 0 {
                if libc::setgroups(0, std::ptr::null()) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::setgid(worker_gid) != 0 || libc::setuid(worker_uid) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
            } else if libc::geteuid() != worker_uid || libc::getegid() != worker_gid {
                return Err(std::io::Error::from_raw_os_error(libc::EPERM));
            }
            Ok(())
        });
    }
    child.spawn().context("spawn root-owned supervised command")
}

fn verify_cleanup(child: &mut Child, config: &DaemonConfig) -> Result<()> {
    let daemon_pid = std::process::id() as i32;
    signal_descendants(daemon_pid, libc::SIGTERM)?;
    if wait_for_no_descendants(child, daemon_pid, config.term_grace)? {
        return Ok(());
    }
    signal_descendants(daemon_pid, libc::SIGKILL)?;
    if wait_for_no_descendants(child, daemon_pid, config.kill_grace)? {
        Ok(())
    } else {
        bail!("live descendants remain after SIGKILL")
    }
}

fn wait_for_no_descendants(child: &mut Child, daemon_pid: i32, grace: Duration) -> Result<bool> {
    let deadline = Instant::now() + grace;
    loop {
        let _ = child.try_wait();
        reap_adopted_children()?;
        if descendant_pids(daemon_pid)?.is_empty() {
            return Ok(true);
        }
        if Instant::now() >= deadline {
            return Ok(false);
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn descendant_pids(root: i32) -> Result<Vec<ProcessIdentity>> {
    let mut parents = HashMap::<i32, Vec<ProcessIdentity>>::new();
    for entry in fs::read_dir("/proc")? {
        let entry = entry?;
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<i32>() else {
            continue;
        };
        if pid == root {
            continue;
        }
        let Ok(stat) = fs::read_to_string(entry.path().join("stat")) else {
            continue;
        };
        let Some(after_name) = stat.rsplit_once(") ").map(|(_, rest)| rest) else {
            continue;
        };
        let fields: Vec<_> = after_name.split_whitespace().collect();
        if fields.len() < 20 || fields[0] == "Z" {
            continue;
        }
        if let (Ok(ppid), Ok(start_time)) = (fields[1].parse::<i32>(), fields[19].parse::<u64>()) {
            parents
                .entry(ppid)
                .or_default()
                .push(ProcessIdentity { pid, start_time });
        }
    }
    let mut descendants = Vec::new();
    let mut pending = vec![root];
    let mut seen = HashSet::new();
    while let Some(parent) = pending.pop() {
        if let Some(children) = parents.get(&parent) {
            for &identity in children {
                if seen.insert(identity.pid) {
                    descendants.push(identity);
                    pending.push(identity.pid);
                }
            }
        }
    }
    Ok(descendants)
}

#[cfg(target_os = "linux")]
fn signal_descendants(root: i32, signal: i32) -> Result<()> {
    let mut descendants = descendant_pids(root)?;
    descendants.reverse();
    for identity in descendants {
        let raw_fd = unsafe { libc::syscall(libc::SYS_pidfd_open, identity.pid, 0) as i32 };
        if raw_fd < 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                continue;
            }
            return Err(error.into());
        }
        let pidfd = unsafe { OwnedFd::from_raw_fd(raw_fd) };
        // Close the snapshot->pidfd race: the pidfd is stable, and we signal it
        // only if its numeric PID still has the captured start time and remains
        // in the daemon-owned ancestry tree.
        if !descendant_pids(root)?.contains(&identity) {
            continue;
        }
        let result = unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                pidfd.as_raw_fd(),
                signal,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            )
        };
        if result != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(error.into());
            }
        }
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn signal_descendants(_root: i32, _signal: i32) -> Result<()> {
    bail!("verified descendant signaling requires Linux pidfds")
}

fn reap_adopted_children() -> Result<()> {
    loop {
        let result = unsafe { libc::waitpid(-1, std::ptr::null_mut(), libc::WNOHANG) };
        if result > 0 {
            continue;
        }
        if result == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ECHILD) {
            return Ok(());
        }
        return Err(error.into());
    }
}

pub fn run_client(config: ClientConfig, command: &[OsString]) -> Result<i32> {
    if command.is_empty() {
        bail!("session command is required");
    }
    let secret_present = TRACKER_SECRETS
        .iter()
        .any(|secret| std::env::var_os(OsStr::from_bytes(secret)).is_some());
    if secret_present || std::env::var_os(SANITIZED_CLIENT_ENV).is_none() {
        let executable = std::env::current_exe()?;
        let mut sanitized = Command::new(executable);
        sanitized.arg("client").arg("--").args(command);
        for secret in TRACKER_SECRETS {
            sanitized.env_remove(OsStr::from_bytes(secret));
        }
        sanitized.env(SANITIZED_CLIENT_ENV, "1");
        return Err(sanitized.exec().into());
    }
    let mut stream = UnixStream::connect(&config.socket)
        .with_context(|| format!("connect {}", config.socket.display()))?;
    stream.set_read_timeout(Some(config.handshake_timeout))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut response = String::new();
    reader.read_line(&mut response)?;
    match response.as_str() {
        "OK\n" => {}
        "BUSY\n" => bail!("worker already owns an active task session"),
        "DENIED\n" => bail!("session supervisor denied this client"),
        other => bail!("unexpected supervisor response: {other:?}"),
    }

    send_stdio(&stream)?;
    write_command(&mut stream, command)?;
    stream.set_read_timeout(Some(config.completion_timeout))?;
    response.clear();
    reader.read_line(&mut response)?;
    if let Some(code) = response
        .strip_prefix("EXIT ")
        .and_then(|value| value.trim().parse().ok())
    {
        Ok(code)
    } else if response == "FAILED\n" || response.is_empty() {
        bail!("session supervisor could not prove process cleanup")
    } else {
        bail!("unexpected completion response: {response:?}")
    }
}

fn send_stdio(stream: &UnixStream) -> Result<()> {
    let fds = [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO];
    sendmsg::<()>(
        stream.as_raw_fd(),
        &[IoSlice::new(b"F")],
        &[ControlMessage::ScmRights(&fds)],
        MsgFlags::empty(),
        None,
    )?;
    Ok(())
}

fn receive_stdio(stream: &UnixStream) -> Result<[File; 3]> {
    let mut marker = [0_u8; 1];
    let mut slices = [IoSliceMut::new(&mut marker)];
    let mut control = nix::cmsg_space!([RawFd; 3]);
    let message = recvmsg::<()>(
        stream.as_raw_fd(),
        &mut slices,
        Some(&mut control),
        MsgFlags::empty(),
    )?;
    let received_bytes = message.bytes;
    let control_messages: Vec<_> = message.cmsgs()?.collect();
    if received_bytes != 1 || marker != *b"F" {
        bail!("invalid stdio descriptor frame");
    }
    let mut received = Vec::new();
    for control_message in control_messages {
        if let ControlMessageOwned::ScmRights(fds) = control_message {
            received.extend(fds);
        }
    }
    if received.len() != 3 {
        for fd in received {
            unsafe { libc::close(fd) };
        }
        bail!("exactly three stdio descriptors are required");
    }
    Ok(received
        .try_into()
        .map(|fds: [RawFd; 3]| fds.map(|fd| unsafe { File::from_raw_fd(fd) }))
        .unwrap())
}

fn write_command(stream: &mut UnixStream, command: &[OsString]) -> Result<()> {
    if command.len() > MAX_ARGUMENTS {
        bail!("too many command arguments");
    }
    let mut total_bytes = 0_usize;
    stream.write_all(&(command.len() as u32).to_be_bytes())?;
    for argument in command {
        let bytes = argument.as_bytes();
        if bytes.len() > MAX_ARGUMENT_BYTES {
            bail!("command argument is too large");
        }
        total_bytes = total_bytes
            .checked_add(bytes.len())
            .filter(|total| *total <= MAX_COMMAND_BYTES)
            .context("command exceeds aggregate size limit")?;
        stream.write_all(&(bytes.len() as u32).to_be_bytes())?;
        stream.write_all(bytes)?;
    }
    Ok(())
}

fn read_command(stream: &mut UnixStream) -> Result<Vec<OsString>> {
    let count = read_u32(stream)? as usize;
    if count == 0 || count > MAX_ARGUMENTS {
        bail!("invalid command argument count");
    }
    let mut command = Vec::with_capacity(count);
    let mut total_bytes = 0_usize;
    for _ in 0..count {
        let length = read_u32(stream)? as usize;
        if length > MAX_ARGUMENT_BYTES {
            bail!("command argument is too large");
        }
        total_bytes = total_bytes
            .checked_add(length)
            .filter(|total| *total <= MAX_COMMAND_BYTES)
            .context("command exceeds aggregate size limit")?;
        let mut bytes = vec![0; length];
        stream.read_exact(&mut bytes)?;
        command.push(OsString::from_vec(bytes));
    }
    Ok(command)
}

fn read_u32(stream: &mut UnixStream) -> Result<u32> {
    let mut bytes = [0_u8; 4];
    stream.read_exact(&mut bytes)?;
    Ok(u32::from_be_bytes(bytes))
}

fn read_peer_cwd(pid: i32, workspace_root: &Path) -> Result<PathBuf> {
    let cwd = fs::canonicalize(format!("/proc/{pid}/cwd"))?;
    let root = fs::canonicalize(workspace_root)?;
    if cwd != root && !cwd.starts_with(&root) {
        bail!("client working directory is outside the workspace root");
    }
    Ok(cwd)
}

fn read_peer_environment(pid: i32) -> Result<Vec<(OsString, OsString)>> {
    let bytes = fs::read(format!("/proc/{pid}/environ"))?;
    let mut environment = Vec::new();
    for entry in bytes
        .split(|byte| *byte == 0)
        .filter(|entry| !entry.is_empty())
    {
        let Some(separator) = entry.iter().position(|byte| *byte == b'=') else {
            continue;
        };
        let name = &entry[..separator];
        if TRACKER_SECRETS.contains(&name) {
            continue;
        }
        environment.push((
            OsString::from_vec(name.to_vec()),
            OsString::from_vec(entry[separator + 1..].to_vec()),
        ));
    }
    Ok(environment)
}

fn claim_active(
    active: &Arc<Mutex<Option<ActiveSession>>>,
    candidate: ActiveSession,
) -> Result<bool> {
    let mut guard = active.lock().map_err(|_| anyhow!("active lock poisoned"))?;
    if guard.is_some() {
        return Ok(false);
    }
    *guard = Some(candidate);
    Ok(true)
}

fn release_active(active: &Arc<Mutex<Option<ActiveSession>>>, owner: ActiveSession) -> Result<()> {
    let mut guard = active.lock().map_err(|_| anyhow!("active lock poisoned"))?;
    if guard.as_ref() == Some(&owner) {
        *guard = None;
        Ok(())
    } else {
        bail!("active session ownership changed during cleanup")
    }
}

#[cfg(target_os = "linux")]
fn become_subreaper() -> Result<()> {
    if unsafe { libc::prctl(libc::PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn become_subreaper() -> Result<()> {
    bail!("session supervisor requires Linux")
}

#[cfg(target_os = "linux")]
fn peer_credentials(stream: &UnixStream) -> Result<(i32, u32)> {
    use std::mem::{size_of, zeroed};
    let mut credentials: libc::ucred = unsafe { zeroed() };
    let mut length = size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut credentials as *mut _ as *mut libc::c_void,
            &mut length,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok((credentials.pid, credentials.uid))
}

#[cfg(not(target_os = "linux"))]
fn peer_credentials(_stream: &UnixStream) -> Result<(i32, u32)> {
    bail!("session supervisor requires Linux SO_PEERCRED")
}

#[cfg(target_os = "linux")]
fn chown_socket(path: &Path, gid: u32) -> Result<()> {
    let path = std::ffi::CString::new(path.as_os_str().as_bytes())?;
    if unsafe { libc::chown(path.as_ptr(), libc::geteuid(), gid) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn chown_socket(_path: &Path, _gid: u32) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_worker_admits_exactly_one_live_owner() {
        let active = Arc::new(Mutex::new(None));
        let first = ActiveSession { owner_pid: 101 };
        let second = ActiveSession { owner_pid: 202 };
        assert!(claim_active(&active, first).unwrap());
        assert!(!claim_active(&active, second).unwrap());
        assert!(release_active(&active, second).is_err());
        assert!(!claim_active(&active, second).unwrap());
        release_active(&active, first).unwrap();
        assert!(claim_active(&active, second).unwrap());
    }

    #[test]
    fn fragmented_command_frames_are_read_exactly() {
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        let handle = thread::spawn(move || {
            write_command(
                &mut writer,
                &[OsString::from("codex"), OsString::from("app-server")],
            )
            .unwrap()
        });
        assert_eq!(
            read_command(&mut reader).unwrap(),
            ["codex", "app-server"].map(OsString::from)
        );
        handle.join().unwrap();
    }

    #[test]
    fn aggregate_command_size_is_bounded() {
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        let handle = thread::spawn(move || {
            writer.write_all(&2_u32.to_be_bytes()).unwrap();
            writer.write_all(&700_000_u32.to_be_bytes()).unwrap();
            writer.write_all(&vec![b'a'; 700_000]).unwrap();
            writer.write_all(&700_000_u32.to_be_bytes()).unwrap();
        });
        assert!(read_command(&mut reader).is_err());
        handle.join().unwrap();
    }

    #[test]
    fn malformed_existing_socket_path_fails_closed() {
        let temporary = tempfile::tempdir().unwrap();
        let socket = temporary.path().join("socket");
        fs::write(&socket, "not a socket").unwrap();
        let config = DaemonConfig::production(socket, unsafe { libc::geteuid() }, unsafe {
            libc::getegid()
        });
        assert!(prepare_socket(&config).is_err());
    }

    #[test]
    fn failed_handshake_acknowledgement_releases_the_pre_spawn_claim() {
        let active = Arc::new(Mutex::new(None));
        let owner = ActiveSession { owner_pid: 101 };
        assert!(claim_active(&active, owner).unwrap());
        let (mut server, client) = UnixStream::pair().unwrap();
        drop(client);

        assert!(acknowledge_claim(&mut server, &active, owner).is_err());
        assert!(claim_active(&active, ActiveSession { owner_pid: 202 }).unwrap());
    }
}
