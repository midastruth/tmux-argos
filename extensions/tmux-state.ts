import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_SESSION_PREFIX = "agent-";
const processGeneration = randomUUID();
let sequence = 0;
let tmuxSession: string | undefined;
let sessionPrefix: string | undefined;

function runTmux(args: string[]): string | undefined {
  try {
    return execFileSync("tmux", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return undefined;
  }
}

function daemonBinary(): string | undefined {
  const configured = runTmux(["show-option", "-gqv", "@agent_daemon_binary"]);
  if (configured && existsSync(configured)) {
    return configured;
  }
  try {
    const here = dirname(realpathSync(fileURLToPath(import.meta.url)));
    const candidate = join(here, "..", "daemon", "target", "release", "tmux-argos-state-daemon");
    return existsSync(candidate) ? candidate : undefined;
  } catch {
    return undefined;
  }
}

function currentTmuxSession(): string | undefined {
  if (tmuxSession) {
    return tmuxSession;
  }
  const pane = process.env.TMUX_PANE;
  if (!pane) {
    return undefined;
  }
  tmuxSession = runTmux(["display-message", "-p", "-t", pane, "#{session_name}"]);
  return tmuxSession;
}

function managedSessionPrefix(): string {
  if (sessionPrefix === undefined) {
    sessionPrefix = runTmux(["show-option", "-gqv", "@agent_session_prefix"]) || DEFAULT_SESSION_PREFIX;
  }
  return sessionPrefix;
}

function isPaneVisible(): boolean {
  const pane = process.env.TMUX_PANE;
  if (!pane) {
    return false;
  }
  const output = runTmux([
    "display-message",
    "-p",
    "-t",
    pane,
    "#{session_attached} #{window_active} #{pane_active}",
  ]);
  if (!output) {
    return false;
  }
  const [attached, windowActive, paneActive] = output.split(" ");
  return attached !== "0" && windowActive === "1" && paneActive === "1";
}

function report(state: "blocked" | "working" | "done" | "idle"): void {
  const pane = process.env.TMUX_PANE;
  if (!pane) {
    return;
  }
  const session = currentTmuxSession();
  if (!session) {
    return;
  }
  sequence += 1;
  const now = Math.floor(Date.now() / 1000).toString();
  const mirrorCommands: string[] = [];
  const addMirrorCommand = (command: string[]) => {
    if (mirrorCommands.length > 0) {
      mirrorCommands.push(";");
    }
    mirrorCommands.push(...command);
  };
  addMirrorCommand(["set-option", "-p", "-t", pane, "@agent_tool", "pi"]);
  addMirrorCommand(["set-option", "-p", "-t", pane, "@agent_state", state]);
  addMirrorCommand(["set-option", "-p", "-t", pane, "@agent_state_at", now]);
  addMirrorCommand([
    "set-option",
    "-p",
    "-t",
    pane,
    "@agent_process_generation",
    processGeneration,
  ]);
  addMirrorCommand(["set-option", "-p", "-t", pane, "@agent_sequence", sequence.toString()]);
  if (session?.startsWith(managedSessionPrefix())) {
    addMirrorCommand(["set-option", "-t", session, "@agent_state", state]);
    addMirrorCommand(["set-option", "-t", session, "@agent_state_at", now]);
    addMirrorCommand([
      "set-option",
      "-t",
      session,
      "@agent_process_generation",
      processGeneration,
    ]);
    addMirrorCommand(["set-option", "-t", session, "@agent_sequence", sequence.toString()]);
    addMirrorCommand(["set-option", "-t", session, "@agent_pane", pane]);
  }
  runTmux(mirrorCommands);

  const binary = daemonBinary();
  if (!binary) {
    return;
  }
  const request = JSON.stringify({
    type: "Report",
    tool: "pi",
    pane_id: pane,
    process_generation: processGeneration,
    sequence,
    state,
    session_name: session,
  });
  try {
    execFileSync(binary, ["send", request], { stdio: "ignore" });
  } catch {
    // Agent operation must not fail because tmux or the local daemon is unavailable.
  }
}

export default function piTmuxStateExtension(pi: ExtensionAPI) {
  pi.on("session_start", async () => report("idle"));
  pi.on("agent_start", async () => report("working"));
  pi.on("agent_end", async () => report(isPaneVisible() ? "idle" : "done"));
  pi.on("session_shutdown", async () => report("idle"));
}
