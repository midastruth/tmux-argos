import assert from "node:assert/strict";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const REJECT_OPTION = "Reject (default)";
const ALLOW_ONCE_OPTION = "Allow this mutation once";
const tests = [];

function test(name, run) {
  tests.push({ name, run });
}

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const extensionUrl = pathToFileURL(resolve(projectRoot, ".pi/extensions/test-constitution.ts"));
const { default: extensionFactory } = await import(extensionUrl.href);

let toolCallHandler;
extensionFactory({
  on(eventName, handler) {
    if (eventName === "tool_call") {
      toolCallHandler = handler;
    }
  },
});
assert.equal(typeof toolCallHandler, "function", "extension must register a tool_call handler");

function createContext({ hasUI = true, selection } = {}) {
  const prompts = [];
  return {
    context: {
      cwd: projectRoot,
      hasUI,
      ui: {
        async select(title, options) {
          prompts.push({ title, options });
          return selection;
        },
      },
    },
    prompts,
  };
}

async function invoke(toolName, input, context) {
  return toolCallHandler({ toolName, input, toolCallId: "test-call" }, context);
}

test("protected capability write is allowed only after one-time approval", async () => {
  const { context, prompts } = createContext({ selection: ALLOW_ONCE_OPTION });
  const result = await invoke("write", { path: "tests/bash_mutation.sh", content: "x" }, context);

  assert.equal(result, undefined);
  assert.equal(prompts.length, 1);
  assert.deepEqual(prompts[0].options, [REJECT_OPTION, ALLOW_ONCE_OPTION]);
  assert.match(prompts[0].title, /write/);
  assert.match(prompts[0].title, /tests\/bash_mutation\.sh/);
});

test("protected edit is blocked when the human keeps the default rejection", async () => {
  const { context, prompts } = createContext({ selection: REJECT_OPTION });
  const result = await invoke("edit", { path: "AGENTS.md", edits: [] }, context);

  assert.deepEqual(result, {
    block: true,
    reason: "Protected mutation rejected by the user.",
  });
  assert.equal(prompts.length, 1);
});

test("cancelling protected mutation confirmation blocks the tool call", async () => {
  const { context } = createContext({ selection: undefined });
  const result = await invoke("edit", { path: ".github/workflows/test.yml", edits: [] }, context);

  assert.deepEqual(result, {
    block: true,
    reason: "Protected mutation rejected by the user.",
  });
});

test("protected mutation without an interactive UI fails closed", async () => {
  const { context, prompts } = createContext({ hasUI: false });
  const result = await invoke("write", { path: ".github/CODEOWNERS", content: "x" }, context);

  assert.deepEqual(result, {
    block: true,
    reason: "Protected mutation requires explicit human approval, but no interactive UI is available.",
  });
  assert.equal(prompts.length, 0);
});

test("protected shell mutation is allowed only after one-time human approval", async () => {
  const command = "printf x > tests/suite_contract.py";
  const { context, prompts } = createContext({ selection: ALLOW_ONCE_OPTION });
  const result = await invoke("bash", { command }, context);

  assert.equal(result, undefined);
  assert.equal(prompts.length, 1);
  assert.match(prompts[0].title, /bash/);
  assert.match(prompts[0].title, /printf x > tests\/suite_contract\.py/);
});

test("behavior-test refactoring proceeds without human approval", async () => {
  const { context, prompts } = createContext({ selection: REJECT_OPTION });
  const result = await invoke("edit", { path: "tests/run.sh", edits: [] }, context);

  assert.equal(result, undefined);
  assert.equal(prompts.length, 0);
});

test("behavior-test shell refactoring proceeds without human approval", async () => {
  const command = "printf x > tests/run.sh";
  const { context, prompts } = createContext({ selection: REJECT_OPTION });
  const result = await invoke("bash", { command }, context);

  assert.equal(result, undefined);
  assert.equal(prompts.length, 0);
});

test("production mutation proceeds without asking for human approval", async () => {
  const { context, prompts } = createContext({ selection: REJECT_OPTION });
  const result = await invoke("edit", { path: "scripts/helpers.sh", edits: [] }, context);

  assert.equal(result, undefined);
  assert.equal(prompts.length, 0);
});

let failures = 0;
for (const { name, run } of tests) {
  try {
    await run();
    console.log(`ok - ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`not ok - ${name}`);
    console.error(error);
  }
}

console.log(`\n${tests.length - failures} passed, ${failures} failed`);
if (failures > 0) {
  process.exit(1);
}
