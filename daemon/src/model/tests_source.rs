    fn source_fixture(server: &IsolatedTmuxServer, pid: i32, directory: &Path) -> SourcePublisher {
        SourcePublisher {
            path: directory.join("source.json"),
            lock_path: directory.join("source.lock"),
            descriptor: SourceDescriptor {
                server_socket: server.socket().into(),
                server_pid: pid,
                state_file: None,
            },
            published: None,
        }
    }

    fn source_test_directory() -> PathBuf {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let directory = std::env::temp_dir().join(format!("argos-source-{}-{nonce}", std::process::id()));
        fs::create_dir(&directory).unwrap();
        directory
    }

    #[test]
    fn source_locator_hashes_socket_without_pid_using_utf8_fnv1a64() {
        assert_eq!(source_socket_hash("/tmp/tmux-1000/default"), "79301cf9592f327a");
        assert_ne!(source_socket_hash("/tmp/A.sock"), source_socket_hash("/tmp/B.sock"));
    }

    #[test]
    fn source_config_changes_publish_actual_path_or_null_with_snapshot_identity() {
        let server = IsolatedTmuxServer::start("source-config");
        let pid = server.run(&["display-message", "-p", "#{pid}"]).trim().parse().unwrap();
        let directory = source_test_directory();
        let first = directory.join("first.json");
        let second = directory.join("second.json");
        let publisher = source_fixture(&server, pid, &directory);
        let descriptor_path = publisher.path.clone();
        let mut center = StateCenter::new(server.socket().into(), exposure_config(ExposureMode::File, Some(first.clone())));
        center.source_publisher = Some(publisher);
        center.publish_state_and_source().unwrap();
        let descriptor: Value = serde_json::from_slice(&fs::read(&descriptor_path).unwrap()).unwrap();
        assert_eq!(descriptor["serverSocket"], server.socket());
        assert_eq!(descriptor["serverPid"], pid);
        assert_eq!(descriptor["stateFile"], first.to_str().unwrap());
        let snapshot: Value = serde_json::from_slice(&fs::read(&first).unwrap()).unwrap();
        assert_eq!(snapshot["serverPid"], pid);
        assert_eq!(snapshot["serverSocket"], server.socket());
        center.replace_config(exposure_config(ExposureMode::File, Some(second.clone())));
        center.publish_state_and_source().unwrap();
        assert!(!first.exists());
        assert!(second.exists());
        let descriptor: Value = serde_json::from_slice(&fs::read(&descriptor_path).unwrap()).unwrap();
        assert_eq!(descriptor["stateFile"], second.to_str().unwrap());
        center.replace_config(exposure_config(ExposureMode::Off, None));
        center.publish_state_and_source().unwrap();
        assert!(!second.exists());
        let descriptor: Value = serde_json::from_slice(&fs::read(&descriptor_path).unwrap()).unwrap();
        assert!(descriptor["stateFile"].is_null());
        center.remove_source_file();
        assert!(!descriptor_path.exists());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn concurrent_stale_publisher_and_cleanup_cannot_replace_new_source_or_custom_snapshot() {
        let server = IsolatedTmuxServer::start("source-ownership");
        let pid: i32 = server.run(&["display-message", "-p", "#{pid}"]).trim().parse().unwrap();
        let directory = source_test_directory();
        let state_path = directory.join("state.json");
        let mut current = source_fixture(&server, pid, &directory);
        current.publish(Some(state_path.clone())).unwrap();
        let source_path = current.path.clone();
        let expected = fs::read(&source_path).unwrap();
        let lock = current.lock().unwrap();
        let mut stale = source_fixture(&server, pid + 1, &directory);
        let worker = std::thread::spawn(move || {
            assert!(stale.publish(None).is_err());
            stale.remove().unwrap();
            stale
        });
        drop(lock);
        let stale = worker.join().unwrap();
        assert_eq!(fs::read(&source_path).unwrap(), expected);
        let mut center = StateCenter::new(server.socket().into(), exposure_config(ExposureMode::File, Some(state_path.clone())));
        center.source_publisher = Some(current);
        center.publish_state_and_source().unwrap();
        let snapshot = fs::read(&state_path).unwrap();
        let mut old_center = StateCenter::new(server.socket().into(), exposure_config(ExposureMode::File, Some(state_path.clone())));
        old_center.source_publisher = Some(stale);
        assert!(old_center.apply(Request::Seen { pane_id: Some("%0".into()) }).is_err());
        assert!(old_center.publish_state_and_source().is_err());
        old_center.published_file_path = Some(state_path.clone());
        old_center.remove_exposure_file();
        old_center.remove_source_file();
        assert_eq!(fs::read(&state_path).unwrap(), snapshot);
        assert_eq!(fs::read(&source_path).unwrap(), expected);
        center.remove_exposure_file();
        center.remove_source_file();
        assert!(!state_path.exists());
        assert!(!source_path.exists());
        fs::remove_dir_all(directory).unwrap();
    }
