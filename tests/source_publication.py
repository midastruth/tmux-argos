#!/usr/bin/env python3
"""Approved source-descriptor lifecycle and stale-daemon regressions."""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def socket_hash(socket):
    value = 0xcbf29ce484222325
    for byte in str(socket).encode():
        value = ((value ^ byte) * 0x100000001b3) & ((1 << 64) - 1)
    return f"{value:016x}"


def wait(predicate):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.02)
    raise AssertionError("source publication did not converge within 5 seconds")


def read(path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None


def test(binary, root):
    home = root / "home"
    home.mkdir()
    environment = dict(os.environ, HOME=str(home), TMPDIR=str(root))
    daemons = []
    sockets = []

    def tmux(socket, *arguments):
        return subprocess.check_output(["tmux", "-S", str(socket), *arguments],
                                       env=environment, text=True, timeout=5).strip()

    def request(env, command):
        result = json.loads(subprocess.check_output([binary, command], env=env,
                                                   text=True, timeout=5))
        assert result["ok"], result

    def start(socket, name):
        sockets.append(socket)
        tmux(socket, "-f", "/dev/null", "new-session", "-d", "-s", name, "sleep 120")
        pid = int(tmux(socket, "display-message", "-p", "#{pid}"))
        env = dict(environment, TMUX=f"{socket},{pid},0")
        process = subprocess.Popen([binary, "serve"], env=env, stdout=subprocess.DEVNULL)
        daemons.append(process)
        source = home / ".cache/tmux-argos/sources" / (socket_hash(socket) + ".json")
        wait(lambda: read(source) and read(source)["serverPid"] == pid)
        return env, process, source, pid

    try:
        socket_a = root / "A.sock"
        env_a, process_a, source_a, pid_a = start(socket_a, "A")
        socket_b = root / "B.sock"
        env_b, process_b, source_b, pid_b = start(socket_b, "B")
        first = read(source_a)
        assert first["serverSocket"] == str(socket_a)
        assert first["serverPid"] == pid_a
        path_a = Path(first["stateFile"])
        path_b = Path(read(source_b)["stateFile"])
        assert path_a != path_b and source_a != source_b
        for path, name in [(path_a, "A"), (path_b, "B")]:
            document = read(path)
            assert document["serverSocket"] in [str(socket_a), str(socket_b)]
            assert document["serverPid"] in [pid_a, pid_b]
            assert document["panes"][0]["sessionName"] == name
            assert document["panes"][0]["paneId"] == "%0"
            assert document["panes"][0]["sessionId"] == "$0"
        assert source_a.stat().st_mode & 0o777 == 0o600
        assert source_a.parent.stat().st_mode & 0o777 == 0o700
        print("ok - distinct sockets publish private descriptors and isolated snapshots despite identical IDs")

        custom = root / "custom/state.json"
        tmux(socket_a, "set-option", "-g", "@agent_state_file", str(custom))
        request(env_a, "reload")
        wait(lambda: read(source_a)["stateFile"] == str(custom))
        assert custom.exists() and not path_a.exists()
        tmux(socket_a, "set-option", "-g", "@agent_state_exposure", "socket")
        request(env_a, "reload")
        wait(lambda: read(source_a)["stateFile"] is None)
        assert not custom.exists() and path_b.exists()
        tmux(socket_a, "set-option", "-g", "@agent_state_exposure", "both")
        request(env_a, "reload")
        wait(lambda: read(source_a)["stateFile"] == str(custom))
        before_invalid = read(source_a)
        tmux(socket_a, "set-option", "-g", "@agent_state_file", "relative.json")
        response = json.loads(subprocess.run([binary, "reload"], env=env_a,
                             capture_output=True, text=True, timeout=5).stdout)
        assert not response["ok"] and read(source_a) == before_invalid
        print("ok - reload publishes the actual path or null and invalid reload retains the valid source")

        # Queue stale publication behind the same socket lock. A new generation
        # must win regardless of which waiting daemon gets the lock first.
        lock_path = source_a.with_suffix(".lock")
        with lock_path.open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            process_a.send_signal(signal.SIGSTOP)
            tmux(socket_a, "kill-server")
            tmux(socket_a, "-f", "/dev/null", "new-session", "-d", "-s", "replacement", "sleep 120")
            new_pid = int(tmux(socket_a, "display-message", "-p", "#{pid}"))
            assert new_pid != pid_a
            tmux(socket_a, "set-option", "-g", "@agent_state_file", str(custom))
            new_env = dict(environment, TMUX=f"{socket_a},{new_pid},0")
            replacement = subprocess.Popen([binary, "serve"], env=new_env, stdout=subprocess.DEVNULL)
            daemons.append(replacement)
            process_a.send_signal(signal.SIGCONT)
            reload_old = subprocess.Popen([binary, "reload"], env=env_a, stdout=subprocess.DEVNULL)
            time.sleep(0.1)
            fcntl.flock(lock, fcntl.LOCK_UN)
        reload_old.wait(timeout=5)
        wait(lambda: read(source_a) and read(source_a)["serverPid"] == new_pid)
        replacement_source = read(source_a)
        request(env_a, "shutdown")
        process_a.wait(timeout=5)
        assert read(source_a) == replacement_source
        assert replacement_source["stateFile"] == str(custom)
        assert read(custom)["serverPid"] == new_pid
        assert read(custom)["panes"][0]["sessionName"] == "replacement"
        # An explicitly restarted stale daemon must not reclaim the description.
        stale = subprocess.Popen([binary, "serve"], env=env_a, stdout=subprocess.DEVNULL)
        daemons.append(stale)
        time.sleep(0.15)
        if stale.poll() is None:
            request(env_a, "shutdown")
        stale.wait(timeout=5)
        assert read(source_a) == replacement_source
        print("ok - same-socket replacement survives concurrent stale reload, shutdown, and startup")

        request(new_env, "shutdown")
        replacement.wait(timeout=5)
        assert not source_a.exists()
        assert read(source_b)["serverPid"] == pid_b and process_b.poll() is None
        request(env_b, "shutdown")
        process_b.wait(timeout=5)
        assert not source_b.exists()
        print("ok - clean shutdown removes only its own source description")
    finally:
        for process in reversed(daemons):
            if process.poll() is None:
                process.send_signal(signal.SIGCONT)
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        for socket in set(sockets):
            subprocess.run(["tmux", "-S", str(socket), "kill-server"], env=environment,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="argos-source-", dir="/tmp") as directory:
        test(str(Path(sys.argv[1]).resolve()), Path(directory))
