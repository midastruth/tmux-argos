import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

const PROTECTED_PATHS = [
  "tests",
  "spec",
  "daemon/fixtures",
  ".github/workflows",
  ".github/extensions/test-constitution.ts",
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
  return PROTECTED_PATHS.some((protectedPath) =>
    command.includes(protectedPath) || command.includes(resolve(projectRoot, protectedPath)),
  );
}

function looksLikeProtectedMutation(command: string): boolean {
  const mutationCommand = /(^|[;&|]\s*)(rm|mv|cp|install|touch|truncate|chmod|chown|ln|tee)\b/;
  const inPlaceEditor = /\b(sed|perl)\b[^\n]*(^|\s)-i/;
  const interpreter = /(^|[;&|]\s*)(python[0-9.]*|ruby|node|deno)\b/;
  const gitMutation = /\bgit\b[^\n]*\b(add|apply|checkout|clean|commit|mv|reset|restore|rm)\b/;
  const outputRedirection = /(^|[;&|]\s*)[^\n]*>{1,2}\s*[^;&|\n]*/;
  const findMutation = /\bfind\b[^\n]*\b(-delete|-exec|-execdir)\b/;

  return mutationCommand.test(command)
    || inPlaceEditor.test(command)
    || interpreter.test(command)
    || gitMutation.test(command)
    || outputRedirection.test(command)
    || findMutation.test(command);
}

const REJECT_OPTION = "Reject (default)";
const ALLOW_ONCE_OPTION = "Allow this mutation once";

type BlockResult = { block: true; reason: string };

async function requestHumanApproval(
  ctx: ExtensionContext,
  toolName: string,
  mutationDetails: string,
): Promise<BlockResult | undefined> {
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
    "Choose whether to allow this single tool call.",
  ].join("\n");
  const selection = await ctx.ui.select(title, [REJECT_OPTION, ALLOW_ONCE_OPTION]);

  if (selection === ALLOW_ONCE_OPTION) {
    return undefined;
  }
  return {
    block: true,
    reason: "Protected mutation rejected by the user.",
  };
}

export default function testConstitution(pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
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
      if (commandReferencesProtectedPath(command, projectRoot) && looksLikeProtectedMutation(command)) {
        return requestHumanApproval(ctx, event.toolName, `Command: ${command}`);
      }
    }

    return undefined;
  });
}
