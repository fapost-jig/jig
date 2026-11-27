// The clone's revision, TypeScript's half of one counter that bash and Go raise as well. Every test
// plants its own repository under a temporary directory: a write here raises a counter, and the
// counter of this clone must stay where it is.

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fixedClock } from "../src/core/clock.ts";
import type { Ctx } from "../src/core/context.ts";
import { exec } from "../src/core/exec.ts";
import { revisionBump, revisionDir, revisionRead } from "../src/core/storage/revision.ts";
import { createTaskState, stateFile, writeTaskState } from "../src/core/storage/state.ts";
import { bashJig, bashLib, makeProject, nativePath, tmpDir } from "./helpers.ts";

const PINNED = 1790000000;
const clock = fixedClock(PINNED);

function ctx(root: string): Ctx {
  return { root, exec, clock, env: {} };
}

/** What bash answers, with the project pinned (JIG_PROJECT) and the clock pinned like ours. */
function bash(root: string, body: string, args: readonly string[] = []): string {
  const r = bashLib(root, body, args, { JIG_PROJECT: root, JIG_NOW: String(PINNED) });
  assert.equal(r.code, 0, r.stderr);
  return r.stdout.trim();
}

function names(dir: string): string {
  return fs.readdirSync(dir).sort().join(" ");
}

const SEED = [
  ["task_id", "t"],
  ["status", "active"],
  ["created_at", "2026-09-21"],
] as const;

test("a repository with no write reads revision 0", (t) => {
  const root = makeProject(tmpDir(t));
  assert.equal(revisionRead(root), 0);
  assert.equal(bash(root, "jig_revision_read"), "0");
  // Names that are not digits only are not the counter.
  fs.mkdirSync(revisionDir(root), { recursive: true });
  for (const n of ["x1", "1x", "1.5", ".7"]) fs.writeFileSync(path.join(revisionDir(root), n), "");
  assert.equal(revisionRead(root), 0);
});

test("a first raise claims the pinned seconds, and bash reads it", (t) => {
  const root = makeProject(tmpDir(t));
  assert.deepEqual(revisionBump(root, clock), { raised: true });
  assert.equal(revisionRead(root), PINNED);
  assert.equal(bash(root, "jig_revision_read"), String(PINNED));
  assert.equal(revisionBump(root, clock).raised, true);
  assert.equal(revisionRead(root), PINNED + 1);
});

test("TypeScript and bash raise one counter", (t) => {
  const root = makeProject(tmpDir(t));
  bash(root, "jig_revision_bump; jig_revision_bump; jig_revision_bump");
  const before = revisionRead(root);
  assert.equal(before, PINNED + 2);
  revisionBump(root, clock);
  bash(root, "jig_revision_bump");
  assert.equal(bash(root, "jig_revision_read"), String(before + 2));
  assert.equal(revisionRead(root), before + 2);
});

test("a file and a directory both count as a name, and the highest wins", (t) => {
  const root = makeProject(tmpDir(t));
  const dir = revisionDir(root);
  fs.mkdirSync(path.join(dir, "50"), { recursive: true });
  fs.writeFileSync(path.join(dir, "7"), "");
  assert.equal(revisionRead(root), 50);
  assert.equal(bash(root, "jig_revision_read"), "50");
  revisionBump(root, clock);
  assert.equal(revisionRead(root), 51);
});

test("raises clear old names as bash does", (t) => {
  const tsRoot = makeProject(tmpDir(t));
  const bashRoot = makeProject(tmpDir(t));
  for (let i = 0; i < 40; i++) assert.equal(revisionBump(tsRoot, clock).raised, true);
  bash(bashRoot, 'n=0; while [ "$n" -lt 40 ]; do jig_revision_bump; n=$((n + 1)); done');
  assert.equal(names(revisionDir(tsRoot)), names(revisionDir(bashRoot)));
  assert.ok(fs.readdirSync(revisionDir(tsRoot)).length <= 17, "stale names were cleared");

  // Stale names of both kinds are withdrawn: a file and a directory far below the counter.
  const dir = revisionDir(tsRoot);
  fs.writeFileSync(path.join(dir, String(PINNED - 100)), "");
  fs.mkdirSync(path.join(dir, String(PINNED - 99)));
  revisionBump(tsRoot, clock);
  assert.equal(fs.existsSync(path.join(dir, String(PINNED - 100))), false);
  assert.equal(fs.existsSync(path.join(dir, String(PINNED - 99))), false);
});

test("a linked worktree raises its main checkout's counter, where bash finds it", (t) => {
  const base = tmpDir(t);
  const main = path.join(base, "main");
  const wt = path.join(base, "wt");
  fs.mkdirSync(path.join(main, ".git", "worktrees", "wt"), { recursive: true });
  fs.writeFileSync(path.join(main, ".git", "worktrees", "wt", "commondir"), "../..\n");
  fs.mkdirSync(wt);
  fs.writeFileSync(path.join(wt, ".git"), `gitdir: ${path.join(main, ".git", "worktrees", "wt")}\n`);
  const want = path.join(main, ".ai", "runtime", "revision");
  assert.equal(revisionDir(main), want);
  assert.equal(revisionDir(wt), want);
  assert.equal(nativePath(bash(wt, "jig_revision_dir")), want);
  assert.equal(revisionBump(wt, clock).raised, true);
  assert.equal(revisionRead(main), PINNED);
  assert.equal(revisionRead(wt), PINNED);
  assert.equal(fs.existsSync(path.join(wt, ".ai")), false);
});

test("a git directory not named .git keeps the counter under it, where bash keeps it", (t) => {
  const base = tmpDir(t);
  const work = path.join(base, "work");
  const gitdir = path.join(base, "repo.git");
  fs.mkdirSync(work);
  fs.mkdirSync(gitdir);
  fs.writeFileSync(path.join(work, ".git"), `gitdir: ${gitdir}\n`);
  const want = path.join(gitdir, "jig", "revision");
  assert.equal(revisionDir(work), want);
  assert.equal(nativePath(bash(work, "jig_revision_dir")), want);
  assert.equal(revisionBump(work, clock).raised, true);
  assert.equal(bash(work, "jig_revision_read"), String(PINNED));

  // A relative gitdir is resolved against the checkout, and a worktree of a bare repository
  // (commondir not named .git) keeps its counter in the common directory.
  const bare = path.join(base, "bare.git");
  const linked = path.join(base, "linked");
  fs.mkdirSync(path.join(bare, "worktrees", "linked"), { recursive: true });
  fs.writeFileSync(path.join(bare, "worktrees", "linked", "commondir"), "../..\n");
  fs.mkdirSync(linked);
  fs.writeFileSync(path.join(linked, ".git"), `gitdir: ${path.join(bare, "worktrees", "linked")}\n`);
  assert.equal(revisionDir(linked), path.join(bare, "jig", "revision"));
  assert.equal(nativePath(bash(linked, "jig_revision_dir")), path.join(bare, "jig", "revision"));
});

test("a state write raises the revision by one, created or rewritten", (t) => {
  const root = makeProject(tmpDir(t));
  assert.equal(revisionRead(root), 0);
  assert.deepEqual(createTaskState(ctx(root), "t", SEED), { revisionRaised: true });
  assert.equal(revisionRead(root), PINNED);
  assert.deepEqual(writeTaskState(ctx(root), "t", { status: "ready" }), { revisionRaised: true });
  assert.equal(revisionRead(root), PINNED + 1);
  writeTaskState(ctx(root), "t", { status: "active", domains: "a" });
  assert.equal(revisionRead(root), PINNED + 2, "one write, one raise, however many keys");
  // A write that is refused changes nothing, the counter included.
  assert.throws(() => writeTaskState(ctx(root), "t", { status: "bad\nvalue" }));
  assert.throws(() => createTaskState(ctx(root), "t", SEED));
  assert.equal(revisionRead(root), PINNED + 2);
});

test("a TypeScript state write moves the revision bash's task list --json reports", (t) => {
  const root = makeProject(tmpDir(t));
  createTaskState(ctx(root), "t", SEED);
  const read = (): number => {
    const r = bashJig(root, ["task", "list", "--json"], { JIG_NOW: String(PINNED) });
    assert.equal(r.code, 0, r.stderr);
    return (JSON.parse(r.stdout) as { revision: number }).revision;
  };
  const before = read();
  assert.equal(before, PINNED);
  writeTaskState(ctx(root), "t", { status: "ready" });
  assert.equal(read(), before + 1);
});

test("a revision that cannot be raised is reported, and the write stays", (t) => {
  const root = makeProject(tmpDir(t));
  const dir = revisionDir(root);
  fs.mkdirSync(dir, { recursive: true });
  fs.mkdirSync(path.join(root, ".ai", "workspace", "tasks", "t"), { recursive: true });
  fs.writeFileSync(stateFile(ctx(root), "t"), "task_id: t\nstatus: active\ncreated_at: 2026-09-21\n");
  fs.chmodSync(dir, 0o555);
  t.after(() => {
    try {
      fs.chmodSync(dir, 0o755); // so that the temporary directory can be removed, if it still is there
    } catch {
      // already removed
    }
  });
  // Root, or a file system that ignores the mode, can still create here: then there is nothing to test.
  try {
    fs.writeFileSync(path.join(dir, "probe"), "", { flag: "wx" });
    fs.rmSync(path.join(dir, "probe"));
    t.skip("the revision directory is writable despite chmod 555");
    return;
  } catch {
    // not writable, as planned
  }
  const r = writeTaskState(ctx(root), "t", { status: "ready" });
  assert.equal(r.revisionRaised, false);
  assert.match(r.warning ?? "", /could not raise the clone revision in .*; a reader may miss this change/);
  assert.match(fs.readFileSync(stateFile(ctx(root), "t"), "utf8"), /^status: ready$/m);
  assert.equal(revisionRead(root), 0);
});
