#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def wait_until(predicate):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.02)
    raise AssertionError("condition did not become true within 5 seconds")


def session_names(path):
    try:
        snapshot = json.loads(path.read_text())
    except FileNotFoundError:
        return []
    return sorted({pane["sessionName"] for pane in snapshot["panes"]})


def published_path(home, name):
    for path in (home / ".cache/tmux-argos").rglob("state.json"):
        if session_names(path) == [name]:
            return path
    return None


def run_test(binary, root):
    home = root / "home"
    home.mkdir()
    environment = dict(os.environ, HOME=str(home), TMPDIR=str(root))
    servers = []
    daemons = []

    def tmux(socket, *arguments):
        return subprocess.check_output(
            ["tmux", "-S", str(socket), *arguments],
            env=environment, text=True, timeout=5,
        ).strip()

    def request(server_environment, command):
        response = json.loads(subprocess.check_output(
            [binary, command],
            env=server_environment, text=True, timeout=5,
        ))
        assert response["ok"], response
        return response

    def start(name):
        socket = root / f"{name}.tmux"
        servers.append(socket)
        tmux(socket, "-f", "/dev/null", "new-session",
             "-d", "-s", name, "sleep 120")
        wait_until(lambda: tmux(
            socket, "display-message", "-p", "#{pane_current_command}"
        ) == "sleep")
        pid = tmux(socket, "display-message", "-p", "#{pid}")
        server_environment = dict(environment, TMUX=f"{socket},{pid},0")
        process = subprocess.Popen(
            [binary, "serve"], env=server_environment,
            stdout=subprocess.DEVNULL,
        )
        daemons.append(process)
        path = wait_until(lambda: published_path(home, name))
        return socket, server_environment, process, path

    try:
        socket_a, env_a, process_a, path_a = start("main-A")
        socket_b, env_b, process_b, path_b = start("test-B")

        assert path_a != path_b, "different servers must use different files"
        assert session_names(path_a) == ["main-A"]
        assert session_names(path_b) == ["test-B"]
        print("ok - different servers publish separate default state files")

        tmux(socket_b, "rename-session", "-t", "test-B", "test-B-renamed")
        wait_until(lambda: session_names(path_b) == ["test-B-renamed"])
        assert session_names(path_a) == ["main-A"]
        print("ok - B topology updates do not overwrite A state")

        request(env_a, "reload")
        request(env_b, "reload")
        assert published_path(home, "main-A") == path_a
        assert published_path(home, "test-B-renamed") == path_b
        print("ok - config reload retains each server's default file path")

        tmux(socket_b, "set-option", "-g", "@agent_state_exposure", "socket")
        request(env_b, "reload")
        wait_until(lambda: not path_b.exists())
        assert session_names(path_a) == ["main-A"]
        print("ok - disabling B file exposure does not remove A state")

        tmux(socket_b, "set-option", "-g", "@agent_state_exposure", "both")
        request(env_b, "reload")
        wait_until(lambda: session_names(path_b) == ["test-B-renamed"])
        request(env_b, "shutdown")
        process_b.wait(timeout=5)
        assert not path_b.exists()
        assert process_a.poll() is None
        assert session_names(path_a) == ["main-A"]
        assert request(env_a, "inspect")["data"]["panes"][0]["sessionName"] == "main-A"
        print("ok - B shutdown removes only B state while A remains available")
    finally:
        for process in reversed(daemons):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        for socket in reversed(servers):
            subprocess.run(
                ["tmux", "-S", str(socket), "kill-server"],
                env=environment, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=5, check=False,
            )


binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="argos-isolation-", dir="/tmp") as directory:
    run_test(binary, Path(directory))
