import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

const PROTECTED_PATHS = [
  "tests/architecture.sh",
  "tests/bash_mutation.sh",
  "tests/flaky.sh",
  "tests/gherkin_contract.py",
  "tests/meta.sh",
  "tests/mutation.sh",
  "tests/perf_smoke.sh",
  "tests/quality.sh",
  "tests/quality_metrics.py",
  "tests/security.sh",
  "tests/suite_contract.py",
  "tests/system.sh",
  "tests/test_constitution.mjs",
  "tests/verify.sh",
  "spec",
  "daemon/fixtures",
  ".github/workflows",
  ".github/CODEOWNERS",
  ".pi/extensions/test-constitution.ts",
  "AGENTS.md",
] as const;

function findProjectRoot(cwd: string): string {
  let candidate = resolve(cwd);
  while (true) {
    if (existsSync(join(candidate, ".git"))) {
      return candidate;
    }
    const parent = dirname(candidate);
    if (parent === candidate) {
      return resolve(cwd);
    }
    candidate = parent;
  }
}

function projectRelativePath(projectRoot: string, cwd: string, inputPath: string): string | undefined {
  const normalizedInput = inputPath.startsWith("@") ? inputPath.slice(1) : inputPath;
  const relativePath = relative(projectRoot, resolve(cwd, normalizedInput)).replaceAll("\\", "/");
  if (relativePath === ".." || relativePath.startsWith("../")) {
    return undefined;
  }
  return relativePath;
}

function isProtectedPath(relativePath: string): boolean {
  return PROTECTED_PATHS.some((protectedPath) =>
    relativePath === protectedPath || relativePath.startsWith(`${protectedPath}/`),
  );
}

function commandReferencesProtectedPath(command: string, projectRoot: string): boolean {
  return PROTECTED_PATHS.some((protectedPath) => {
    const absPath = resolve(projectRoot, protectedPath);
    if (command.includes(absPath)) {
      return true;
    }
    const escaped = protectedPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const pattern = new RegExp(`(^|[\\s"';&|<>()=\`\\[\\]{}])${escaped}($|[\\s"';&|<>()=\`\\[\\]{}]|\\/)`);
    return pattern.test(command);
  });
}

function redirectsToProtectedPath(command: string, projectRoot: string): boolean {
  const redirectRegex = /(?:^|[\s;&|])(?:\d*|&)(?:>>|>)\s*(?:["']?([^\s;&|<>()"']+?)["']?)(?:\s|[;&|<>()]|$)/g;
  let match: RegExpExecArray | null;
  while ((match = redirectRegex.exec(command)) !== null) {
    const rawTarget = match[1];
    if (!rawTarget || rawTarget.startsWith("&")) {
      continue;
    }
    const cleanTarget = rawTarget.replace(/^\.\//, "");
    const isProtected = PROTECTED_PATHS.some((protectedPath) => {
      const absProtected = resolve(projectRoot, protectedPath);
      const absTarget = resolve(projectRoot, cleanTarget);
      return (
        cleanTarget === protectedPath ||
        cleanTarget.startsWith(`${protectedPath}/`) ||
        absTarget === absProtected ||
        absTarget.startsWith(`${absProtected}/`)
      );
    });
    if (isProtected) {
      return true;
    }
  }
  return false;
}

function looksLikeProtectedMutation(command: string, projectRoot: string): boolean {
  if (redirectsToProtectedPath(command, projectRoot)) {
    return true;
  }

  const mutationCommand = /(^|[;&|]\s*)(rm|mv|cp|install|touch|truncate|chmod|chown|ln|tee)\b/;
  const inPlaceEditor = /\b(sed|perl)\b[^\n]*(^|\s)-i/;
  const inlineInterpreter = /(^|[;&|]\s*)(python[0-9.]*|ruby|node|deno)\b[^\n]*\s+(-c|-e)\b/;
  const gitWorkingTreeMutation = /\bgit\b[^\n]*\b(apply|checkout|clean|mv|reset|restore|rm)\b/;
  const findMutation = /\bfind\b[^\n]*\b(-delete|-exec|-execdir)\b/;

  return (
    mutationCommand.test(command) ||
    inPlaceEditor.test(command) ||
    inlineInterpreter.test(command) ||
    gitWorkingTreeMutation.test(command) ||
    findMutation.test(command)
  );
}

const REJECT_OPTION = "Reject (default)";
const ALLOW_ONCE_OPTION = "Allow this mutation once";
const ALLOW_SESSION_OPTION = "Allow for this session";

type BlockResult = { block: true; reason: string };

const sessionApprovals = new WeakMap<object, boolean>();

function getSessionKey(ctx: ExtensionContext): object {
  const manager = (ctx as { sessionManager?: object }).sessionManager;
  if (manager && typeof manager === "object") {
    return manager;
  }
  return ctx;
}

async function requestHumanApproval(
  ctx: ExtensionContext,
  toolName: string,
  mutationDetails: string,
): Promise<BlockResult | undefined> {
  const sessionKey = getSessionKey(ctx);
  if (sessionApprovals.get(sessionKey) === true) {
    return undefined;
  }

  if (!ctx.hasUI) {
    return {
      block: true,
      reason: "Protected mutation requires explicit human approval, but no interactive UI is available.",
    };
  }

  const title = [
    "Protected executable specification mutation",
    "",
    `Tool: ${toolName}`,
    mutationDetails,
    "",
    "Choose whether to allow this mutation.",
  ].join("\n");
  const selection = await ctx.ui.select(title, [
    REJECT_OPTION,
    ALLOW_ONCE_OPTION,
    ALLOW_SESSION_OPTION,
  ]);

  if (selection === ALLOW_ONCE_OPTION) {
    return undefined;
  }
  if (selection === ALLOW_SESSION_OPTION) {
    sessionApprovals.set(sessionKey, true);
    return undefined;
  }
  return {
    block: true,
    reason: "Protected mutation rejected by the user.",
  };
}

export default function testConstitution(pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    const sessionKey = getSessionKey(ctx);
    if (sessionApprovals.get(sessionKey) === true) {
      return undefined;
    }

    const projectRoot = findProjectRoot(ctx.cwd);

    if (event.toolName === "write" || event.toolName === "edit") {
      const inputPath = event.input.path;
      if (typeof inputPath !== "string") {
        return { block: true, reason: "A file mutation without an explicit path is not allowed." };
      }

      const relativePath = projectRelativePath(projectRoot, ctx.cwd, inputPath);
      if (relativePath !== undefined && isProtectedPath(relativePath)) {
        return requestHumanApproval(ctx, event.toolName, `Path: ${relativePath}`);
      }
      return undefined;
    }

    if (event.toolName === "bash") {
      const command = event.input.command;
      if (typeof command !== "string") {
        return { block: true, reason: "A shell call without an explicit command is not allowed." };
      }
      if (commandReferencesProtectedPath(command, projectRoot) && looksLikeProtectedMutation(command, projectRoot)) {
        return requestHumanApproval(ctx, event.toolName, `Command: ${command}`);
      }
    }

    return undefined;
  });
}
