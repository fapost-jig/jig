// The pause `context resolve --task <id> --stage <s>` honours, and what it does when it cannot; the revision claim the
// queue write is made against; the global framework a manifest names; the paths built from a task id; the queue's file.
// The process runner is a fake (context-helpers.ts, `fakeGit`); no test here runs git.

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fixedClock } from "../src/core/clock.ts";
import { cancelPauseRequest } from "../src/core/queue/write.ts";
import { adaptersDir, globalSource } from "../src/core/storage/adapters.ts";
import { queueFile, writeQueueText } from "../src/core/storage/queue.ts";
import { revisionBump, revisionClaim, revisionRead } from "../src/core/storage/revision.ts";
import { appendTaskFile } from "../src/core/storage/tasks.ts";
import { resolveContext } from "../src/core/context/resolve.ts";
import type { JigCtx } from "../src/core/context.ts";
import { dispatcherRoot, pathEntries } from "../src/core/storage/adapters.ts";
import { fakeGit, jigContext, knowledgeProject, task, write } from "./context-helpers.ts";
import { repoRoot } from "./helpers.ts";

const QUEUE = "# jig queue 1 — x\nitem\ttask:t1\t-\t100\t-\nrequest\ttask:t1\tpause\t2026-11-27T14:00:00Z\twhy\n";
const clock = fixedClock(1795788180);

/** Whether mode 555 really stops a file being made in `dir` (not for root, nor on Windows, where the read-only bit does not): restores the mode. */
function chmodBlocksWrites(dir: string): boolean {
  fs.chmodSync(dir, 0o555);
  try {
    fs.writeFileSync(path.join(dir, ".probe"), "", { flag: "wx" });
    fs.rmSync(path.join(dir, ".probe"));
    return false;
  } catch {
    return true;
  } finally {
    fs.chmodSync(dir, 0o755);
  }
}

function paused(dir: string): { dir: string } {
  task(dir, "t1", { status: "active", branch: "main", created_at: "2026-01-01" });
  write(dir, ".ai/runtime/queue", QUEUE);
  return { dir };
}

const stageCall = (dir: string): ReturnType<typeof jigContext> => jigContext(dir, ["resolve", "--task", "t1", "--stage", "plan", "--files", "x"]);

test("the revision claim: the name above the revision read, refused when the clone moved, never lowering it", (t) => {
  const dir = knowledgeProject(t);
  assert.equal(revisionClaim(dir, clock, 0), "claimed");
  assert.equal(revisionRead(dir), 1795788180);
  assert.equal(revisionClaim(dir, clock, 0), "stale");
  assert.equal(revisionClaim(dir, clock, 5), "stale");
  assert.equal(revisionClaim(dir, clock, 1795788180), "claimed");
  assert.equal(revisionRead(dir), 1795788181);
  assert.equal(revisionClaim(dir, clock, 1795788180), "stale");
  revisionBump(dir, clock);
  assert.equal(revisionRead(dir), 1795788182);
});

test("cancelling a pause request claims the revision read before the queue, and raises it once more after the write", (t) => {
  const dir = knowledgeProject(t);
  write(dir, ".ai/runtime/queue", QUEUE);
  const before = revisionRead(dir);
  const r = cancelPauseRequest({ root: dir, clock }, "t1", before);
  assert.deepEqual(r, { kind: "taken", at: "2026-11-27T14:00:00Z", reason: "why" });
  assert.equal(revisionRead(dir), before === 0 ? 1795788181 : before + 2);
  assert.equal(fs.readFileSync(queueFile({ root: dir }), "utf8"), "# jig queue 1 — written by `jig queue` only; do not edit by hand\nitem\ttask:t1\t-\t100\t-\n");
  assert.deepEqual(cancelPauseRequest({ root: dir, clock }, "t1", revisionRead(dir)), { kind: "none" });
});

test("a cancel against a revision the clone has moved past is stale, and leaves the queue as it was", (t) => {
  const dir = knowledgeProject(t);
  write(dir, ".ai/runtime/queue", QUEUE);
  revisionBump(dir, clock);
  const read = revisionRead(dir);
  revisionBump(dir, clock);
  assert.deepEqual(cancelPauseRequest({ root: dir, clock }, "t1", read), { kind: "stale" });
  assert.equal(fs.readFileSync(queueFile({ root: dir }), "utf8"), QUEUE);
  assert.equal(revisionRead(dir), read + 1);
});

test("a revision that keeps moving between the read and the claim: three stale tries, the warning, the request standing, then the context", async (t) => {
  const dir = paused(knowledgeProject(t)).dir;
  let moves = 0;
  const ctx: JigCtx = {
    root: dir,
    exec: fakeGit(dir).exec,
    clock,
    env: {},
    keys: { local: new Set(), localOnly: new Set() },
    lib: undefined,
    beforeQueueClaim: () => {
      moves++;
      revisionBump(dir, clock);
    },
  };
  let out = "";
  let err = "";
  const code = await resolveContext(
    ctx,
    { task: "t1", taskNamed: true, noTask: false, stage: "plan", files: "x", domains: "", topics: "", ids: "", catalog: false, all: false },
    { out: (x) => (out += x), err: (x) => (err += x) },
  );
  assert.equal(moves, 3);
  assert.equal(code, 0);
  assert.equal(err, "jig: warning: context: the pause requested for t1 was not honoured: jig: error: task pause: the queue kept changing; the pause request of t1 stays\n");
  assert.match(out, /^global: /);
  assert.equal(fs.readFileSync(queueFile({ root: dir }), "utf8"), QUEUE);
  assert.equal(fs.readFileSync(path.join(dir, ".ai/workspace/tasks/t1/state"), "utf8").includes("paused"), false);
});

test("a pause is honoured: the request leaves the queue, the task is paused, exit 4", async (t) => {
  const { dir } = paused(knowledgeProject(t));
  const r = await stageCall(dir);
  assert.equal(r.code, 4);
  assert.match(r.out, /^paused: t1 \(pause requested at 2026-11-27T14:00:00Z: why\); stage plan not entered\nnext: /);
  assert.equal(fs.readFileSync(path.join(dir, ".ai/workspace/tasks/t1/state"), "utf8").includes("paused: true"), true);
});

test("a pause that cannot be made is a warning naming why, then the context: .ai/runtime unwritable", async (t) => {
  const { dir } = paused(knowledgeProject(t));
  if (!chmodBlocksWrites(path.join(dir, ".ai/runtime"))) return t.skip("chmod 555 does not stop writing here (root, or Windows)");
  fs.chmodSync(path.join(dir, ".ai/runtime"), 0o555);
  let r;
  try {
    r = await stageCall(dir);
  } finally {
    fs.chmodSync(path.join(dir, ".ai/runtime"), 0o755);
  }
  assert.equal(r.code, 0);
  assert.match(r.out, /^global: /);
  assert.match(r.err, /^jig: warning: context: the pause requested for t1 was not honoured: jig: error: task pause: cannot take the pause request of t1 out of the queue: exit 1: queue: cannot claim the clone revision in /);
  assert.match(fs.readFileSync(queueFile({ root: dir }), "utf8"), /request\ttask:t1\tpause/);
});

test("a pause that cannot be made is a warning naming why, then the context: the task directory unwritable", async (t) => {
  const { dir } = paused(knowledgeProject(t));
  const taskDir = path.join(dir, ".ai/workspace/tasks/t1");
  if (!chmodBlocksWrites(taskDir)) return t.skip("chmod 555 does not stop writing here (root, or Windows)");
  fs.chmodSync(taskDir, 0o555);
  let r;
  try {
    r = await stageCall(dir);
  } finally {
    fs.chmodSync(taskDir, 0o755);
  }
  assert.equal(r.code, 0);
  assert.match(r.out, /^global: /);
  assert.match(r.err, /^jig: warning: context: the pause requested for t1 was not honoured: jig: error: .*EACCES/);
});

test("a manifest naming the global framework finds the adapters through the jig on PATH", (t) => {
  const dir = knowledgeProject(t);
  write(dir, ".ai/manifest", "jig.version: 1\njig.source: global\n---\n");
  const root = fs.realpathSync(repoRoot);
  const scripts = path.join(repoRoot, "scripts");
  assert.equal(globalSource({ PATH: ["/nonexistent", scripts].join(path.delimiter) }), root);
  assert.equal(adaptersDir({ root: dir, env: { PATH: scripts } }, undefined), path.join(root, "adapters"));
  assert.equal(adaptersDir({ root: dir, env: { PATH: "/nonexistent" } }, undefined), undefined);
  // reached through a link (a link needs a privilege on Windows: only where it can be made)
  const bin = path.join(dir, "bin");
  fs.mkdirSync(bin);
  try {
    fs.symlinkSync(path.join(scripts, "jig"), path.join(bin, "jig"));
    assert.equal(globalSource({ PATH: bin }), root);
    fs.rmSync(path.join(bin, "jig"));
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "EPERM") throw e;
  }
  // a jig that is not a framework checkout's dispatcher is no global source
  fs.writeFileSync(path.join(bin, "jig"), "#!/bin/sh\n", { mode: 0o755 });
  assert.equal(globalSource({ PATH: bin }), undefined);
});

test("PATH is split on the platform's delimiter and the dispatcher recognised in either separator", () => {
  assert.deepEqual(pathEntries("/a:/b::/c", path.posix), ["/a", "/b", "", "/c"]);
  assert.deepEqual(pathEntries("C:\\bin;D:\\tools\\jig", path.win32), ["C:\\bin", "D:\\tools\\jig"]);
  assert.equal(dispatcherRoot("/opt/jig/scripts/jig", path.posix), "/opt/jig");
  assert.equal(dispatcherRoot("C:\\src\\jig\\scripts\\jig", path.win32), "C:\\src\\jig");
  assert.equal(dispatcherRoot("C:\\src\\jig\\bin\\jig", path.win32), undefined);
  assert.equal(path.win32.isAbsolute("C:\\bin\\jig"), true);
});

test("every path built from a task id goes through the validating builder", (t) => {
  const dir = knowledgeProject(t);
  assert.throws(() => appendTaskFile({ root: dir, clock }, "../x", "autopilot", "x\n"), /invalid task id/);
  assert.throws(() => appendTaskFile({ root: dir, clock }, "", "autopilot", "x\n"), /invalid task id/);
});

test("the queue is written through a temporary: the directory is made, and nothing is left behind when the write fails", (t) => {
  const dir = knowledgeProject(t);
  fs.rmSync(path.join(dir, ".ai/runtime"), { recursive: true, force: true });
  assert.equal(writeQueueText({ root: dir }, "# jig queue 1\n"), true);
  assert.equal(fs.readFileSync(queueFile({ root: dir }), "utf8"), "# jig queue 1\n");
  fs.rmSync(queueFile({ root: dir }));
  fs.mkdirSync(queueFile({ root: dir }));
  assert.equal(writeQueueText({ root: dir }, "x\n"), false);
  assert.deepEqual(fs.readdirSync(path.join(dir, ".ai/runtime")), ["queue"]);
});
