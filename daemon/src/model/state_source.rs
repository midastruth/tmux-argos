use std::os::fd::AsRawFd;

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct SourceDescriptor {
    server_socket: String,
    server_pid: i32,
    state_file: Option<PathBuf>,
}

struct SourcePublisher {
    path: PathBuf,
    lock_path: PathBuf,
    descriptor: SourceDescriptor,
    published: Option<SourceDescriptor>,
}

fn source_socket_hash(socket: &str) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in socket.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

impl SourcePublisher {
    fn new(socket: &str, pid: i32) -> Result<Self, String> {
        if !Path::new(socket).is_absolute() || pid <= 1 {
            return Err("source publication requires an absolute socket and valid PID".into());
        }
        let home = std::env::var_os("HOME").ok_or("HOME is required for source publication")?;
        let directory = PathBuf::from(home).join(".cache/tmux-argos/sources");
        fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
            .map_err(|error| error.to_string())?;
        let stem = source_socket_hash(socket);
        let publisher = Self {
            path: directory.join(format!("{stem}.json")),
            lock_path: directory.join(format!("{stem}.lock")),
            descriptor: SourceDescriptor {
                server_socket: socket.to_string(),
                server_pid: pid,
                state_file: None,
            },
            published: None,
        };
        let _lock = publisher.lock()?;
        publisher.validate_server()?;
        Ok(publisher)
    }

    fn lock(&self) -> Result<fs::File, String> {
        // This lock is socket-scoped, not PID-scoped, and is never unlinked:
        // replacement generations must serialize on the same inode.
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(&self.lock_path)
            .map_err(|error| error.to_string())?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        Ok(file)
    }

    fn validate_server(&self) -> Result<(), String> {
        let actual_pid = tmux_output(
            &self.descriptor.server_socket,
            &["display-message", "-p", "#{pid}"],
        )
        .ok_or("source server is unavailable")?;
        if actual_pid.trim() != self.descriptor.server_pid.to_string() {
            return Err("source server restarted; stale daemon cannot publish".into());
        }
        Ok(())
    }

    fn current_server_lock(&self) -> Result<fs::File, String> {
        let lock = self.lock()?;
        self.validate_server()?;
        Ok(lock)
    }

    fn snapshot_is_owned(&self, contents: &[u8]) -> Result<bool, String> {
        let snapshot: Value = serde_json::from_slice(contents)
            .map_err(|error| error.to_string())?;
        Ok(snapshot["serverSocket"] == self.descriptor.server_socket
            && snapshot["serverPid"] == self.descriptor.server_pid)
    }

    fn publish(&mut self, state_file: Option<PathBuf>) -> Result<bool, String> {
        self.descriptor.state_file = state_file;
        if self.published.as_ref() == Some(&self.descriptor) && self.path.exists() {
            return Ok(false);
        }
        let _lock = self.lock()?;
        // Validate inside the publication lock, not before waiting for it.
        // An old daemon waiting during a restart must not reclaim the source.
        self.validate_server()?;
        let mut contents = serde_json::to_vec(&self.descriptor)
            .map_err(|error| error.to_string())?;
        contents.push(b'\n');
        atomic_write_private(&self.path, &contents)?;
        self.published = Some(self.descriptor.clone());
        Ok(true)
    }

    fn remove(&self) -> Result<(), String> {
        let _lock = self.lock()?;
        let Some(contents) = read_optional_file(&self.path)? else {
            return Ok(());
        };
        let owner: SourceDescriptor = serde_json::from_slice(&contents)
            .map_err(|error| error.to_string())?;
        if owner.server_socket == self.descriptor.server_socket
            && owner.server_pid == self.descriptor.server_pid
        {
            fs::remove_file(&self.path).map_err(|error| error.to_string())?;
        }
        Ok(())
    }
}

impl StateCenter {
    pub fn enable_source_publication(&mut self, server_pid: i32) -> Result<(), String> {
        self.source_publisher = Some(SourcePublisher::new(&self.server_socket, server_pid)?);
        Ok(())
    }

    fn publish_state_and_source(&mut self) -> Result<(), String> {
        // Only advertise a new path after its complete snapshot exists.
        self.publish_exposure_file()?;
        if let Some(publisher) = &mut self.source_publisher {
            publisher.publish(self.config.state_file.clone())?;
        }
        Ok(())
    }

    pub fn remove_source_file(&mut self) {
        if let Some(publisher) = self.source_publisher.take() {
            if let Err(error) = publisher.remove() {
                eprintln!("tmux-argos-state-daemon: source cleanup failed: {error}");
            }
        }
    }
}
