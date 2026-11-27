// `jig context` without a subcommand, in-process against a project on disk (tests/context.t.sh, the stateless form).
//
// The process runner is a fake (context-helpers.ts, `fakeGit`). The tests that run the real git are two:
// "git-derived files: committed, staged, ..." and "a base branch that does not exist leaves the working tree alone".

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { doc, fakeGit, git, jigContext, knowledgeProject, task, write } from "./context-helpers.ts";

const GLOBALS = "global:    .ai/knowledge/GLOSSARY.md\nglobal:    .ai/knowledge/ARCHITECTURE.md\nglobal:    .ai/knowledge/RULES.md\n";

test("files: a glob row names the matching document and its glob", async (t) => {
  const dir = knowledgeProject(t);
  doc(dir, "features/flow.md", { id: "feature-flow", type: "feature", status: "active", paths: ["src/Flow/**"] });
  const r = await jigContext(dir, ["--files", "src/Flow/A.php"]);
  assert.equal(r.code, 0);
  assert.equal(r.out, `${GLOBALS}matched:   .ai/knowledge/features/flow.md  (paths: src/Flow/**)\n`);
  assert.equal(r.err, "");
});

test("files: a csv list, stdin, and an empty value that falls back to the checkout's changes", async (t) => {
  const dir = knowledgeProject(t);
  doc(dir, "features/a.md", { id: "a", type: "feature", status: "active", paths: ["a.php"] });
  doc(dir, "features/b.md", { id: "b", type: "feature", status: "active", paths: ["b.php"] });
  const csv = await jigContext(dir, ["--files", "a.php,b.php"]);
  assert.match(csv.out, /a\.md {2}\(paths: a\.php\)\nmatched: {3}\.ai\/knowledge\/features\/b\.md/);
  const stdin = await jigContext(dir, ["--files", "-"], {}, "b.php\n\n");
  assert.match(stdin.out, /b\.md/);
  assert.doesNotMatch(stdin.out, /a\.md/);
  const none = await jigContext(dir, ["--files", ""]);
  assert.doesNotMatch(none.out, /matched/);
});

test("files: matched documents are sorted by path, and a glob is matched literally for ? and []", async (t) => {
  const dir = knowledgeProject(t);
  doc(dir, "features/z.md", { id: "z", type: "feature", status: "active", paths: ["x"] });
  doc(dir, "adr/a.md", { id: "a", type: "adr", status: "accepted", paths: ["x"] });
  doc(dir, "features/lit.md", { id: "l", type: "feature", status: "active", paths: ["src/a?b[c].php"] });
  const r = await jigContext(dir, ["--files", "x"]);
  assert.deepEqual(r.out.split("\n").filter((l) => l.startsWith("matched")), [
    "matched:   .ai/knowledge/adr/a.md  (paths: x)",
    "matched:   .ai/knowledge/features/z.md  (paths: x)",
  ]);
  assert.doesNotMatch((await jigContext(dir, ["--files", "src/axbc.php"])).out, /lit\.md/);
  assert.match((await jigContext(dir, ["--files", "src/a?b[c].php"])).out, /lit\.md/);
});

test("domains: explicit, from the task's state, and an explicit list overrides the task's", async (t) => {
  const dir = knowledgeProject(t);
  doc(dir, "features/pay.md", { id: "pay", type: "feature", status: "active", domains: ["payments"] });
  doc(dir, "features/ship.md", { id: "ship", type: "feature", status: "active", domains: ["shipping"] });
  const explicit = await jigContext(dir, ["--files", "none", "--domains", "payments, other"]);
  assert.match(explicit.out, /pay\.md {2}\(domains: payments\)/);
  task(dir, "t1", { status: "active", branch: "other", domains: "payments" });
  const fromTask = await jigContext(dir, ["--task", "t1", "--files", "none"]);
  assert.match(fromTask.out, /pay\.md/);
  const override = await jigContext(dir, ["--task", "t1", "--files", "none", "--domains", "shipping"]);
  assert.match(override.out, /ship\.md/);
  assert.doesNotMatch(override.out, /pay\.md/);
  assert.doesNotMatch((await jigContext(dir, ["--files", "none"])).out, /matched/);
});

test("status: only active and accepted are matched unless --all; load: stage is never listed", async (t) => {
  const dir = knowledgeProject(t);
  for (const s of ["active", "accepted", "proposed", "superseded", "weird"]) doc(dir, `features/${s}.md`, { id: s, type: "feature", status: s, paths: ["x"] });
  doc(dir, "features/staged.md", { id: "st", type: "feature", status: "active", load: "stage", paths: ["x"] });
  const r = await jigContext(dir, ["--files", "x", "--format", "paths"]);
  assert.equal(r.out, `.ai/knowledge/GLOSSARY.md\n.ai/knowledge/ARCHITECTURE.md\n.ai/knowledge/RULES.md\n.ai/knowledge/features/accepted.md\n.ai/knowledge/features/active.md\n`);
  const all = await jigContext(dir, ["--files", "x", "--all", "--format", "paths"]);
  assert.match(all.out, /proposed\.md/);
  assert.match(all.out, /weird\.md/);
  assert.doesNotMatch(all.out, /staged\.md/);
});

test("global documents are listed when present and omitted when absent; nothing at all prints nothing", async (t) => {
  const dir = knowledgeProject(t);
  fs.rmSync(path.join(dir, ".ai/knowledge/ARCHITECTURE.md"));
  assert.equal((await jigContext(dir, ["--files", "x"])).out, "global:    .ai/knowledge/GLOSSARY.md\nglobal:    .ai/knowledge/RULES.md\n");
  fs.rmSync(path.join(dir, ".ai/knowledge/GLOSSARY.md"));
  fs.rmSync(path.join(dir, ".ai/knowledge/RULES.md"));
  const none = await jigContext(dir, ["--files", "x"]);
  assert.deepEqual([none.code, none.out, none.err], [0, "", ""]);
});

test("a stub is read through its source, and a matched stub with a missing source is fatal", async (t) => {
  const dir = knowledgeProject(t);
  write(dir, "docs/adr.md", "# adr\n");
  doc(dir, "adr/stub.md", { id: "stub-1", type: "adr", status: "active", source: "docs/adr.md", paths: ["x"] });
  const r = await jigContext(dir, ["--files", "x"]);
  assert.match(r.out, /matched: {3}docs\/adr\.md {2}\(paths: x; linked by stub-1\)/);
  assert.equal((await jigContext(dir, ["--files", "x", "--format", "paths"])).out.split("\n").pop(), "");
  fs.rmSync(path.join(dir, "docs/adr.md"));
  const dead = await jigContext(dir, ["--files", "x"]);
  assert.equal(dead.code, 1);
  assert.equal(dead.out, "");
  assert.equal(dead.err, "jig: error: context: .ai/knowledge/adr/stub.md is selected but its source docs/adr.md is missing; fix the link or reject the stub\n");
  // not matched: not fatal
  assert.equal((await jigContext(dir, ["--files", "y"])).code, 0);
});

test("a source that is a link, or lies under a link that leaves the repository, is missing", async (t) => {
  const dir = knowledgeProject(t);
  write(dir, "real.md", "# r\n");
  fs.symlinkSync("real.md", path.join(dir, "link.md"));
  doc(dir, "adr/a.md", { id: "a", type: "adr", status: "active", source: "link.md", paths: ["x"] });
  assert.equal((await jigContext(dir, ["--files", "x"])).code, 1);
  const outside = path.join(path.dirname(dir), `${path.basename(dir)}-outside`);
  fs.mkdirSync(outside);
  t.after(() => fs.rmSync(outside, { recursive: true, force: true }));
  fs.writeFileSync(path.join(outside, "f.md"), "# f\n");
  fs.symlinkSync(outside, path.join(dir, "ext"));
  doc(dir, "adr/a.md", { id: "a", type: "adr", status: "active", source: "ext/f.md", paths: ["x"] });
  assert.equal((await jigContext(dir, ["--files", "x"])).code, 1);
  fs.mkdirSync(path.join(dir, "inner"));
  fs.writeFileSync(path.join(dir, "inner/f.md"), "# f\n");
  fs.symlinkSync("inner", path.join(dir, "inside"));
  doc(dir, "adr/a.md", { id: "a", type: "adr", status: "active", source: "inside/f.md", paths: ["x"] });
  assert.equal((await jigContext(dir, ["--files", "x"])).code, 0);
});

test("workspace: task.md, then the artifacts in their fixed order; none without a task", async (t) => {
  const dir = knowledgeProject(t);
  task(dir, "t1", { status: "active", branch: "other" });
  for (const f of ["review.md", "plan.md", "discovery.md"]) write(dir, `.ai/workspace/tasks/t1/${f}`, "x\n");
  const r = await jigContext(dir, ["--task", "t1", "--files", "x"]);
  assert.equal(
    r.out.split("\n").filter((l) => l.startsWith("workspace")).join("|"),
    "workspace: .ai/workspace/tasks/t1/task.md|workspace: .ai/workspace/tasks/t1/discovery.md|workspace: .ai/workspace/tasks/t1/plan.md|workspace: .ai/workspace/tasks/t1/review.md",
  );
  assert.doesNotMatch((await jigContext(dir, ["--no-task", "--files", "x"])).out, /workspace/);
});

test("task resolution: the current branch's task, none silently, several listed on stderr, paused ones left out", async (t) => {
  const dir = knowledgeProject(t);
  assert.equal((await jigContext(dir, ["--files", "x"])).err, "");
  task(dir, "T-1", { status: "active", branch: "main", updated_at: "2026-01-01" });
  assert.match((await jigContext(dir, ["--files", "x"])).out, /workspace: .*T-1\/task\.md/);
  task(dir, "T-2", { status: "ready", branch: "main", updated_at: "2026-01-02" });
  const many = await jigContext(dir, ["--files", "x"]);
  assert.equal(many.code, 0);
  assert.doesNotMatch(many.out, /workspace/);
  assert.equal(many.err, "T-1  active  updated_at=2026-01-01\nT-2  ready  updated_at=2026-01-02\n");
  assert.match((await jigContext(dir, ["--task", "T-1", "--files", "x"])).out, /T-1\/task\.md/);
  fs.appendFileSync(path.join(dir, ".ai/workspace/tasks/T-1/state"), "paused: true\n");
  const one = await jigContext(dir, ["--files", "x"]);
  assert.match(one.out, /T-2\/task\.md/);
  assert.equal(one.err, "");
});

test("errors: unknown task, bad id, conflicts, bad options, usage, no project", async (t) => {
  const dir = knowledgeProject(t);
  const fails = async (args: string[], message: string): Promise<void> => {
    const r = await jigContext(dir, args);
    assert.deepEqual([r.code, r.out, r.err], [1, "", `jig: error: ${message}\n`], args.join(" "));
  };
  await fails(["--task", "NOPE"], "context: unknown task: NOPE");
  await fails(["--task", "../x"], "invalid task id: ../x");
  await fails(["--task", "a", "--no-task"], "context: --task conflicts with --no-task");
  await fails(["--bogus"], "context: unknown argument: --bogus");
  await fails(["--format", "bogus"], "context: invalid --format: bogus (want list or paths)");
  await fails(["--files"], "context: --files requires a value");
  await fails(["--task"], "context: --task requires a value");
  await fails(["--stage", "plan"], "context: --stage requires the progressive form; use jig context resolve");
  const usage = await jigContext(dir, ["bogus"]);
  assert.equal(usage.code, 1);
  assert.match(usage.err, /^jig: error: usage: jig context \[--task <id>\]/);
  assert.match(usage.err, /selectors: --task <id>\|--no-task/);
  const bare = knowledgeProject(t);
  fs.rmSync(path.join(bare, ".ai/config.yaml"));
  assert.equal((await jigContext(bare, [])).err, "jig: error: project is not initialised; run: jig init\n");
  const outside = fs.mkdtempSync(path.join(fs.realpathSync(path.dirname(dir)), "jig-none-"));
  t.after(() => fs.rmSync(outside, { recursive: true, force: true }));
  assert.equal((await jigContext(outside, [], {}, "", fakeGit(outside, { notARepository: true }))).err, "jig: error: not inside a git repository\n");
});

test("git-derived files: committed, staged, unstaged and untracked changes, against the task's own base", async (t) => {
  const dir = knowledgeProject(t, undefined, true);
  for (const n of ["committed", "modified", "untracked", "staged"]) doc(dir, `features/${n}.md`, { id: n, type: "feature", status: "active", paths: [`${n}.php`] });
  write(dir, "README.md", "r\n");
  git(dir, "add", ".");
  git(dir, "commit", "-q", "-m", "base");
  git(dir, "checkout", "-q", "-b", "feature");
  write(dir, "committed.php", "<?php\n");
  git(dir, "add", "committed.php");
  git(dir, "commit", "-q", "-m", "c");
  write(dir, "staged.php", "<?php\n");
  git(dir, "add", "staged.php");
  fs.appendFileSync(path.join(dir, "README.md"), "x\n");
  write(dir, "untracked.php", "<?php\n");
  doc(dir, "features/readme.md", { id: "readme", type: "feature", status: "active", paths: ["README.md"] });
  const r = await jigContext(dir, ["--no-task", "--format", "paths"]);
  for (const n of ["committed", "staged", "untracked", "readme"]) assert.match(r.out, new RegExp(`features/${n}\\.md`));
  assert.doesNotMatch(r.out, /modified\.md/);
  // a task cut from `feature` sees only what came after it
  task(dir, "t1", { status: "active", branch: "other", base_branch: "feature" });
  git(dir, "branch", "-q", "feature2");
  const own = await jigContext(dir, ["--task", "t1", "--format", "paths"]);
  assert.doesNotMatch(own.out, /committed\.md/);
  assert.match(own.out, /staged\.md/);
});

test("a base branch that does not exist leaves the working tree alone", async (t) => {
  const dir = knowledgeProject(t, "git.base_branch: nowhere\n", true);
  doc(dir, "features/n.md", { id: "n", type: "feature", status: "active", paths: ["new.php"] });
  write(dir, "new.php", "<?php\n");
  assert.match((await jigContext(dir, ["--format", "paths"])).out, /features\/n\.md/);
});

test("queue lines follow the workspace; the paths form and a task not in the queue have none", async (t) => {
  const dir = knowledgeProject(t);
  task(dir, "t1", { status: "active", branch: "other" });
  task(dir, "a", { status: "active", branch: "other" });
  write(
    dir,
    ".ai/runtime/queue",
    [
      "# jig queue 1",
      "item\ttask:a\t-\t1\t-",
      "item\ttask:t1\tepic:big\t1\t0",
      "dep\ttask:t1\ttask:a\tneeds a",
      "request\ttask:t1\tpause\t2026-01-01T00:00:00Z\tstandup",
      "",
    ].join("\n"),
  );
  const r = await jigContext(dir, ["--task", "t1", "--files", "x"]);
  const queue = r.out.split("\n").filter((l) => l.startsWith("queue:"));
  assert.deepEqual(queue, [
    "queue:     1 of 1 on epic:big, priority 0",
    "queue:     waits for task:a: needs a",
    "queue:     pause requested 330 days ago (standup); honoured when the next stage of the task resolves its context",
  ]);
  assert.match((await jigContext(dir, ["--task", "a", "--files", "x"])).out, /queue: {5}1 of 1 on the top level, no priority\n$/);
  assert.doesNotMatch((await jigContext(dir, ["--task", "t1", "--files", "x", "--format", "paths"])).out, /queue/);
  write(dir, ".ai/runtime/queue", "# jig queue 2\nitem\ttask:t1\t-\t1\t0\n");
  assert.doesNotMatch((await jigContext(dir, ["--task", "t1", "--files", "x"])).out, /queue:/);
});

test("git-derived files with a fake git: the merge base with the task's own base, then the staged, unstaged and untracked lists", async (t) => {
  const dir = knowledgeProject(t, "git.base_branch: main\n");
  for (const n of ["a", "b", "c", "d"]) doc(dir, `features/${n}.md`, { id: n, type: "feature", status: "active", paths: [`${n}.php`] });
  task(dir, "t1", { status: "active", branch: "other", base_branch: "epic" });
  const git = fakeGit(dir, {
    refs: ["refs/remotes/origin/epic", "refs/heads/main"],
    mergeBase: "abc",
    diffBase: ["a.php"],
    cached: ["b.php"],
    unstaged: ["a.php", "c.php"],
    untracked: ["d.php"],
  });
  const r = await jigContext(dir, ["--task", "t1", "--format", "paths"], {}, "", git);
  assert.deepEqual(r.out.split("\n").filter((l) => l.includes("features")), [1, 2, 3, 4].map((i) => `.ai/knowledge/features/${"abcd"[i - 1] as string}.md`));
  assert.ok(git.calls.includes("rev-parse --verify --quiet refs/remotes/origin/epic^{commit}"));
  assert.ok(git.calls.includes("merge-base refs/remotes/origin/epic HEAD"));
  assert.ok(git.calls.includes("diff --name-only abc"));
  // no base ref: only the working tree is asked
  const bare = fakeGit(dir, { cached: ["b.php"] });
  const r2 = await jigContext(dir, ["--no-task", "--format", "paths"], {}, "", bare);
  assert.match(r2.out, /b\.md/);
  assert.equal(bare.calls.some((c) => c.startsWith("merge-base")), false);
});

test("git is asked for the branch once per call, however many readers want it", async (t) => {
  const dir = knowledgeProject(t);
  task(dir, "t1", { status: "active", branch: "main" });
  const git = fakeGit(dir);
  await jigContext(dir, ["--files", "x"], {}, "", git);
  assert.equal(git.calls.filter((c) => c.startsWith("symbolic-ref")).length, 1);
  assert.equal(git.calls.filter((c) => c === "rev-parse --show-toplevel").length, 1);
});

test("an unexpected git call fails the test instead of passing silently", async (t) => {
  const dir = knowledgeProject(t);
  const git = fakeGit(dir);
  await assert.rejects(git.exec("git", ["-c", "core.fsmonitor=false", "-C", dir, "status"]), /unexpected git call: status/);
});
