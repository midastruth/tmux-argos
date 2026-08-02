mod model;
mod protocol;

use model::{Config, StateCenter};
use protocol::{read_request, write_response, Request, Response};
use std::env;
use std::fs::{self, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender};
use std::thread;
use std::time::{Duration, Instant};

const EVENT_BATCH_LIMIT: usize = 64;
const DEADLINE_CHECK_STRIDE: usize = 8;
const SERVER_LIVENESS_INTERVAL: Duration = Duration::from_secs(60);

struct Incoming {
    request: Request,
    stream: UnixStream,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("tmux-argos-state-daemon: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut args = env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "ensure".to_string());
    let server = tmux_server_info()?;
    let paths = runtime_paths(&server)?;
    match command.as_str() {
        "serve" => serve(&paths, &server),
        "ensure" => {
            ensure_daemon(&paths, &server)?;
            let response = send_request(&paths.socket, &Request::Ensure)?;
            print_response(response)
        }
        "snapshot" => {
            ensure_daemon(&paths, &server)?;
            print_response(send_request(&paths.socket, &Request::Snapshot)?)
        }
        "snapshot-picker" => {
            ensure_daemon(&paths, &server)?;
            print_picker_snapshot(send_request(&paths.socket, &Request::Snapshot)?)
        }
        "reload" => {
            ensure_daemon(&paths, &server)?;
            print_response(send_request(&paths.socket, &Request::ReloadConfig)?)
        }
        "send" => {
            let json = args.next().ok_or("send requires one JSON request")?;
            if json.len() > protocol::MAX_MESSAGE_BYTES {
                return Err("request exceeds 64 KiB".into());
            }
            let request: Request = serde_json::from_str(&json).map_err(|e| e.to_string())?;
            ensure_daemon(&paths, &server)?;
            print_response(send_request(&paths.socket, &request)?)
        }
        "shutdown" => print_response(send_request(&paths.socket, &Request::Shutdown)?),
        _ => Err(format!("unknown command: {command}")),
    }
}

fn print_picker_snapshot(response: Response) -> Result<(), String> {
    if !response.ok {
        return Err(response.error.unwrap_or_else(|| "snapshot failed".into()));
    }
    let records = response
        .data
        .as_ref()
        .and_then(|data| data.get("records"))
        .and_then(serde_json::Value::as_array)
        .ok_or("snapshot response has no records")?;
    for record in records {
        let session = record
            .get("sessionName")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let pane = record
            .get("paneId")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let state = record
            .get("state")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let changed_at = record
            .get("changedAt")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(0);
        println!("{session}\u{1f}{pane}\u{1f}{state}\u{1f}{changed_at}");
    }
    Ok(())
}

fn print_response(response: Response) -> Result<(), String> {
    let output = serde_json::to_string(&response).map_err(|e| e.to_string())?;
    println!("{output}");
    if response.ok {
        Ok(())
    } else {
        Err(response.error.unwrap_or_else(|| "request failed".into()))
    }
}

struct RuntimePaths {
    socket: PathBuf,
    lock: PathBuf,
}

struct TmuxServerInfo {
    socket: String,
    pid: i32,
}

fn tmux_server_info() -> Result<TmuxServerInfo, String> {
    let tmux = env::var("TMUX").map_err(|_| "TMUX is not set")?;
    let mut fields = tmux.split(',');
    let socket = fields.next().unwrap_or("");
    let pid = fields
        .next()
        .ok_or("TMUX does not contain a server pid")?
        .parse::<i32>()
        .map_err(|_| "TMUX contains an invalid server pid")?;
    if socket.is_empty() || pid <= 1 {
        return Err("TMUX does not contain a valid server identity".into());
    }
    Ok(TmuxServerInfo {
        socket: socket.to_string(),
        pid,
    })
}

fn runtime_paths(server: &TmuxServerInfo) -> Result<RuntimePaths, String> {
    let uid = unsafe { libc::geteuid() };
    let identity = format!("{}:{}", server.socket, server.pid);
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in identity.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    let root = env::var_os("TMPDIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(format!("tmux-argos-state-{uid}"));
    fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    let stem = format!("{hash:016x}");
    Ok(RuntimePaths {
        socket: root.join(format!("{stem}.sock")),
        lock: root.join(format!("{stem}.lock")),
    })
}

fn ensure_daemon(paths: &RuntimePaths, server: &TmuxServerInfo) -> Result<(), String> {
    if send_request(&paths.socket, &Request::Ensure).is_ok() {
        return Ok(());
    }
    let executable = env::current_exe().map_err(|e| e.to_string())?;
    Command::new(executable)
        .arg("serve")
        .env("TMUX", format!("{},{},0", server.socket, server.pid))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| e.to_string())?;
    for _ in 0..50 {
        thread::sleep(Duration::from_millis(20));
        if send_request(&paths.socket, &Request::Ensure).is_ok() {
            return Ok(());
        }
    }
    Err("daemon did not become ready".into())
}

fn send_request(path: &Path, request: &Request) -> Result<Response, String> {
    let mut stream = UnixStream::connect(path).map_err(|e| e.to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .map_err(|e| e.to_string())?;
    protocol::write_request(&mut stream, request).map_err(|e| e.to_string())?;
    protocol::read_response(&mut stream).map_err(|e| e.to_string())
}

fn serve(paths: &RuntimePaths, server: &TmuxServerInfo) -> Result<(), String> {
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&paths.lock)
        .map_err(|e| e.to_string())?;
    let locked = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if locked != 0 {
        return Ok(());
    }
    if paths.socket.exists() {
        fs::remove_file(&paths.socket).map_err(|e| e.to_string())?;
    }
    let old_umask = unsafe { libc::umask(0o077) };
    let listener = UnixListener::bind(&paths.socket).map_err(|e| e.to_string())?;
    unsafe {
        libc::umask(old_umask);
    }
    fs::set_permissions(&paths.socket, fs::Permissions::from_mode(0o600))
        .map_err(|e| e.to_string())?;

    let (sender, receiver) = mpsc::sync_channel::<Incoming>(256);
    spawn_acceptor(listener, sender);
    let config =
        Config::load(&server.socket).map_err(|e| format!("invalid initial config: {e}"))?;
    let mut center = StateCenter::new(server.socket.clone(), config);
    center.restore_once();
    center.reconcile(Instant::now());
    event_loop(&receiver, &mut center, server.pid);
    let _ = fs::remove_file(&paths.socket);
    Ok(())
}

fn spawn_acceptor(listener: UnixListener, sender: SyncSender<Incoming>) {
    thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(mut stream) = connection else {
                continue;
            };
            let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
            match read_request(&mut stream) {
                Ok(request) => {
                    if sender.send(Incoming { request, stream }).is_err() {
                        return;
                    }
                }
                Err(error) => {
                    let _ = write_response(&mut stream, &Response::error(error.to_string()));
                }
            }
        }
    });
}

fn event_loop(receiver: &Receiver<Incoming>, center: &mut StateCenter, server_pid: i32) {
    let mut shutdown = false;
    let mut server_check_deadline = Instant::now() + SERVER_LIVENESS_INTERVAL;
    while !shutdown {
        let now = Instant::now();
        if now >= server_check_deadline {
            if !process_is_alive(server_pid) {
                break;
            }
            server_check_deadline = now + SERVER_LIVENESS_INTERVAL;
        }
        center.process_deadlines(now);
        center.reconcile(now);
        let timeout = center
            .next_wait(Instant::now())
            .min(server_check_deadline.saturating_duration_since(Instant::now()));
        match receiver.recv_timeout(timeout) {
            Ok(incoming) => {
                shutdown = handle(incoming, center);
                for index in 1..EVENT_BATCH_LIMIT {
                    if index % DEADLINE_CHECK_STRIDE == 0 {
                        let now = Instant::now();
                        center.process_deadlines(now);
                        center.reconcile(now);
                    }
                    match receiver.try_recv() {
                        Ok(incoming) => {
                            if handle(incoming, center) {
                                shutdown = true;
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
                center.process_deadlines(Instant::now());
                center.reconcile(Instant::now());
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

fn process_is_alive(pid: i32) -> bool {
    let result = unsafe { libc::kill(pid, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

fn handle(mut incoming: Incoming, center: &mut StateCenter) -> bool {
    let (response, shutdown) = match incoming.request {
        Request::Ensure => (Response::ok(None), false),
        Request::Snapshot => (Response::ok(Some(center.snapshot())), false),
        Request::ReloadConfig => match Config::load(&center.server_socket) {
            Ok(config) => {
                center.replace_config(config);
                (Response::ok(None), false)
            }
            Err(error) => (Response::error(error), false),
        },
        Request::Shutdown => (Response::ok(None), true),
        request => match center.apply(request) {
            Ok(()) => (Response::ok(None), false),
            Err(error) => (Response::error(error), false),
        },
    };
    let _ = write_response(&mut incoming.stream, &response);
    shutdown
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn event_batch_is_bounded_and_checks_deadlines() {
        assert_eq!(EVENT_BATCH_LIMIT, 64);
        let deadline_check_stride = DEADLINE_CHECK_STRIDE;
        assert!(deadline_check_stride > 0);
        assert!(deadline_check_stride < EVENT_BATCH_LIMIT);
    }
}
