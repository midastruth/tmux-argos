    use std::thread;

    /// Private tmux server that is killed even when the test panics, so a
    /// failing assertion never leaks a background server.
    struct IsolatedTmuxServer {
        socket_path: PathBuf,
    }

    impl IsolatedTmuxServer {
        fn start(label: &str) -> Self {
            let directory = std::env::temp_dir().join(format!(
                "tmux-argos-{label}-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            fs::create_dir_all(&directory).unwrap();
            let server = Self {
                socket_path: directory.join("socket"),
            };
            server.run(&["-f", "/dev/null", "new-session", "-d", "-x", "80", "-y", "24"]);
            server
        }

        fn socket(&self) -> &str {
            self.socket_path.to_str().unwrap()
        }

        fn run(&self, args: &[&str]) -> String {
            let output = Command::new("tmux")
                .arg("-S")
                .arg(&self.socket_path)
                .args(args)
                .output()
                .expect("real tmux is required for screen I/O tests");
            assert!(
                output.status.success(),
                "tmux {args:?} failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8_lossy(&output.stdout).trim_end().to_string()
        }

        fn wait_for_screen(&self, pane_id: &str, expected: &str) {
            for _ in 0..50 {
                if self.run(&["capture-pane", "-p", "-t", pane_id]).contains(expected) {
                    return;
                }
                thread::sleep(Duration::from_millis(20));
            }
            panic!("pane {pane_id} never showed {expected:?}");
        }
    }

    impl Drop for IsolatedTmuxServer {
        fn drop(&mut self) {
            let _ = Command::new("tmux")
                .arg("-S")
                .arg(&self.socket_path)
                .arg("kill-server")
                .output();
            if let Some(directory) = self.socket_path.parent() {
                let _ = fs::remove_dir_all(directory);
            }
        }
    }

    #[test]
    fn batch_capture_accepts_the_daemon_dash_prefixed_marker_on_real_tmux() {
        let server = IsolatedTmuxServer::start("batch-capture");
        let first_pane = server.run(&["display-message", "-p", "#{pane_id}"]);
        let second_pane = server.run(&["split-window", "-d", "-P", "-F", "#{pane_id}"]);
        server.run(&["send-keys", "-t", &first_pane, "clear; echo first-screen", "Enter"]);
        server.run(&["send-keys", "-t", &second_pane, "clear; echo second-screen", "Enter"]);
        server.wait_for_screen(&first_pane, "first-screen");
        server.wait_for_screen(&second_pane, "second-screen");

        // Same shape as the production marker built in StateCenter::new: it
        // starts with "--", which tmux would parse as an option terminator.
        let marker = "--tmux-argos-daemon-split-0000000000000000--";
        let screens = capture_panes_batch(server.socket(), marker, &[&first_pane, &second_pane])
            .expect("batch capture must succeed when every target pane exists");

        assert_eq!(screens.len(), 2);
        assert!(screens[&first_pane].contains("first-screen"));
        assert!(!screens[&first_pane].contains("second-screen"));
        assert!(screens[&second_pane].contains("second-screen"));
        assert!(!screens[&second_pane].contains(marker));
    }
