// The checkout recorder a `context` call leaves behind (jig_checkout_record).
//
// The process runner is a fake (context-helpers.ts, `fakeGit`). The one test that runs the real git is
// "a task whose branch is checked out in another worktree is not work here" (a real `git worktree add`).

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { git, jigContext, knowledgeProject, task, write } from "./context-helpers.ts";

const SESSION = { CLAUDE_CODE_SESSION_ID: "sess-1" };

function read(dir: string, rel: string): string | undefined {
  try {
    return fs.readFileSync(path.join(dir, rel), "utf8");
  } catch {
    return undefined;
  }
}

test("every call records its words in runtime/checkout, and keeps branch_reported", async (t) => {
  const dir = knowledgeProject(t);
  await jigContext(dir, ["--files", "a,b"]);
  assert.equal(read(dir, ".ai/runtime/checkout"), "command: context --files a,b\n");
  write(dir, ".ai/runtime/checkout", "command: x\nbranch_reported: main\n");
  await jigContext(dir, ["--no-task"]);
  assert.equal(read(dir, ".ai/runtime/checkout"), "command: context --no-task\nbranch_reported: main\n");
});

test("nothing is recorded outside an initialised project, nor under JIG_INTERNAL_REDRAW", async (t) => {
  const dir = knowledgeProject(t);
  await jigContext(dir, [], { JIG_INTERNAL_REDRAW: "1" });
  assert.equal(read(dir, ".ai/runtime/checkout"), undefined);
  fs.rmSync(path.join(dir, ".ai/config.yaml"));
  await jigContext(dir, []);
  assert.equal(read(dir, ".ai/runtime/checkout"), undefined);
});

test("a working record is named by the task the words name, else the task on this branch, else the session", async (t) => {
  const dir = knowledgeProject(t);
  await jigContext(dir, ["--files", "x"]);
  assert.equal(fs.existsSync(path.join(dir, ".ai/runtime/working")), false);
  task(dir, "on-main", { status: "active", branch: "main" });
  await jigContext(dir, ["--files", "x"]);
  assert.equal(read(dir, ".ai/runtime/working/on-main"), "command: context --files x\n");
  task(dir, "named", { status: "active", branch: "feature" });
  await jigContext(dir, ["--task", "named", "--files", "x"]);
  assert.match(read(dir, ".ai/runtime/working/named") ?? "", /^command: context --task named --files x\n$/);
});

test("a task whose branch is checked out in another worktree is not work here", async (t) => {
  const dir = knowledgeProject(t, undefined, true);
  git(dir, "worktree", "add", "-q", "-b", "elsewhere", path.join(path.dirname(dir), `${path.basename(dir)}-wt`));
  t.after(() => fs.rmSync(path.join(path.dirname(dir), `${path.basename(dir)}-wt`), { recursive: true, force: true }));
  task(dir, "far", { status: "active", branch: "elsewhere" });
  await jigContext(dir, ["--task", "far", "--files", "x"]);
  assert.equal(read(dir, ".ai/runtime/working/far"), undefined);
});

test("the session id is the runtime's, only while an adapters directory is reachable", async (t) => {
  const dir = knowledgeProject(t);
  await jigContext(dir, ["--files", "x"], SESSION);
  // the framework checkout the tests run from holds adapters/, so the session names the record
  assert.equal(read(dir, ".ai/runtime/working/sess-1"), "command: context --files x\n");
  task(dir, "t1", { status: "active", branch: "feature" });
  await jigContext(dir, ["--task", "t1"], SESSION);
  assert.equal(read(dir, ".ai/runtime/working/t1"), "command: context --task t1\nsession: sess-1\n");
});

test("a command that works a task is a taken record, kept while live, and raises the revision", async (t) => {
  const dir = knowledgeProject(t);
  task(dir, "t1", { status: "active", branch: "feature" });
  await jigContext(dir, ["--task", "t1", "--files", "x"], SESSION);
  const file = ".ai/runtime/taken/t1/sess-1";
  const first = read(dir, file) ?? "";
  assert.match(first, new RegExp(`^checkout: ${dir.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\nsince: 2026-11-27T[0-9:]{8}Z\ncommand: context --task t1 --files x\n$`));
  assert.equal(fs.readdirSync(path.join(dir, ".ai/runtime/revision")).length > 0, true);
  const since = /since: (.*)/.exec(first)?.[1];
  await jigContext(dir, ["--task", "t1"], { ...SESSION, JIG_NOW: "1795788999" });
  assert.match(read(dir, file) ?? "", new RegExp(`since: ${since}\ncommand: context --task t1\n`));
  // no session, no record
  task(dir, "t2", { status: "active", branch: "feature" });
  await jigContext(dir, ["--task", "t2"]);
  assert.equal(fs.existsSync(path.join(dir, ".ai/runtime/taken/t2")), false);
});

test("a resumed session takes the end mark off its taken record", async (t) => {
  const dir = knowledgeProject(t);
  write(dir, ".ai/runtime/taken/t9/sess-1", "checkout: /x\nsince: 2026-01-01T00:00:00Z\ncommand: c\nended: 2026-01-02T00:00:00Z\n");
  await jigContext(dir, ["--files", "x"], SESSION);
  assert.equal(read(dir, ".ai/runtime/taken/t9/sess-1"), "checkout: /x\nsince: 2026-01-01T00:00:00Z\ncommand: c\n");
});
