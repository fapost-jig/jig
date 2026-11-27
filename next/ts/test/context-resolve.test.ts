// `jig context resolve`, in-process against a project on disk (tests/context.t.sh: resolve_*, cache_*, sdd_*, stage_only_*).
//
// The process runner is a fake (context-helpers.ts, `fakeGit`). The one test that runs the real git is
// "the cache is written for a task, served while nothing changed, ..." (the fingerprint hashes every document with `git hash-object`).

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { doc, jigContext, knowledgeProject, task, write } from "./context-helpers.ts";

const GLOBALS = "global:    .ai/knowledge/GLOSSARY.md\nglobal:    .ai/knowledge/ARCHITECTURE.md\nglobal:    .ai/knowledge/RULES.md\n";
const resolve = (dir: string, args: string[], env: Record<string, string> = {}, stdin = ""): ReturnType<typeof jigContext> =>
  jigContext(dir, ["resolve", ...args], env, stdin);

test("load: always is required with no selectors; load: domain is the domain or the files; matched needs a path or topic", async (t) => {
  const dir = knowledgeProject(t);
  doc(dir, "features/always.md", { id: "always", type: "feature", status: "active", load: "always" });
  doc(dir, "features/dom.md", { id: "dom", type: "feature", status: "active", load: "domain", domains: ["pay"], paths: ["src/pay/**"] });
  doc(dir, "features/matched.md", { id: "m", type: "feature", status: "active", domains: ["pay"], paths: ["src/m/**"], topics: ["tx"] });
  const none = await resolve(dir, ["--no-task", "--files", "zzz"]);
  assert.equal(none.out, `${GLOBALS}required:  .ai/knowledge/features/always.md  (load: always)\n`);
  const byDomain = await resolve(dir, ["--no-task", "--files", "zzz", "--domains", "pay"]);
  assert.match(byDomain.out, /dom\.md {2}\(domains: pay\)/);
  assert.doesNotMatch(byDomain.out, /matched\.md {2}\(/);
  const byFiles = await resolve(dir, ["--no-task", "--files", "src/pay/a.php"]);
  assert.match(byFiles.out, /dom\.md {2}\(paths: src\/pay\/\*\*\)/);
  const byTopic = await resolve(dir, ["--no-task", "--files", "zzz", "--topics", "tx,other"]);
  assert.match(byTopic.out, /matched\.md {2}\(topics: tx\)/);
  const byStage = await resolve(dir, ["--no-task", "--files", "zzz"]);
  assert.doesNotMatch(byStage.out, /matched\.md/);
});

test("stage: a stage-only document is required at its stage and never otherwise; a matched one needs stage and domain", async (t) => {
  const dir = knowledgeProject(t);
  doc(dir, "features/only.md", { id: "only", type: "feature", status: "active", load: "stage", stages: ["implement"], paths: ["x"] });
  doc(dir, "features/sd.md", { id: "sd", type: "feature", status: "active", stages: ["review"], domains: ["pay"] });
  const at = await resolve(dir, ["--no-task", "--stage", "implement", "--files", "zzz"]);
  assert.match(at.out, /only\.md {2}\(load: stage; stage: implement\)/);
  assert.doesNotMatch((await resolve(dir, ["--no-task", "--stage", "review", "--files", "x"])).out, /only\.md/);
  assert.match((await resolve(dir, ["--no-task", "--stage", "review", "--domains", "pay", "--files", "zzz"])).out, /sd\.md {2}\(stage: review; domain: pay\)/);
  assert.doesNotMatch((await resolve(dir, ["--no-task", "--stage", "implement", "--domains", "pay", "--files", "zzz", "--catalog"])).out, /catalog:.*only\.md/);
});

test("ids promote a catalog document; an unknown id is fatal; requires closes transitively and a missing one is fatal", async (t) => {
  const dir = knowledgeProject(t);
  doc(dir, "features/a.md", { id: "a", type: "feature", status: "active", paths: ["x"], requires: ["b"] });
  doc(dir, "features/b.md", { id: "b", type: "feature", status: "active", requires: ["c"] });
  doc(dir, "features/c.md", { id: "c", type: "feature", status: "active" });
  const r = await resolve(dir, ["--no-task", "--files", "x"]);
  assert.deepEqual(r.out.split("\n").filter((l) => l.startsWith("required")), [
    "required:  .ai/knowledge/features/a.md  (paths: x)",
    "required:  .ai/knowledge/features/b.md  (requires: a)",
    "required:  .ai/knowledge/features/c.md  (requires: b)",
  ]);
  const ids = await resolve(dir, ["--no-task", "--files", "zzz", "--ids", "c"]);
  assert.match(ids.out, /c\.md {2}\(id: c\)/);
  const unknown = await resolve(dir, ["--no-task", "--ids", "nope"]);
  assert.deepEqual([unknown.code, unknown.err], [1, "jig: error: context: no active document with id: nope\n"]);
  doc(dir, "features/b.md", { id: "b", type: "feature", status: "active", requires: ["gone"] });
  const dead = await resolve(dir, ["--no-task", "--files", "x"]);
  assert.equal(dead.err, "jig: error: context: .ai/knowledge/features/b.md requires unknown or inactive document: gone; run: jig knowledge check\n");
  doc(dir, "features/b.md", { id: "b", type: "feature", status: "proposed" });
  assert.equal((await resolve(dir, ["--no-task", "--files", "x"])).code, 1);
});

test("catalog: unrequired documents of the entered domains and project-wide ones, with a placeholder summary", async (t) => {
  const dir = knowledgeProject(t);
  doc(dir, "features/pay.md", { id: "pay", type: "feature", status: "active", domains: ["payments"], summary: "pays" });
  doc(dir, "features/wide.md", { id: "wide", type: "adr", status: "accepted" });
  doc(dir, "features/paths.md", { id: "pt", type: "feature", status: "active", paths: ["q"] });
  doc(dir, "features/other.md", { id: "o", type: "feature", status: "active", domains: ["shipping"] });
  const without = await resolve(dir, ["--no-task", "--files", "zzz", "--domains", "payments"]);
  assert.doesNotMatch(without.out, /catalog/);
  const r = await resolve(dir, ["--no-task", "--files", "zzz", "--domains", "payments", "--catalog"]);
  assert.deepEqual(r.out.split("\n").filter((l) => l.startsWith("catalog")), [
    "catalog:   .ai/knowledge/features/pay.md  [pay] pays",
    "catalog:   .ai/knowledge/features/wide.md  [wide] (no summary)",
  ]);
});

test("a stub resolves to its source and says which stub linked it; a missing source is fatal only when selected", async (t) => {
  const dir = knowledgeProject(t);
  write(dir, "docs/adr.md", "# adr\n");
  doc(dir, "adr/stub.md", { id: "stub-1", type: "adr", status: "active", source: "docs/adr.md", paths: ["x"] });
  assert.match((await resolve(dir, ["--no-task", "--files", "x"])).out, /required: {2}docs\/adr\.md {2}\(paths: x; linked by stub-1\)/);
  fs.rmSync(path.join(dir, "docs/adr.md"));
  assert.equal(
    (await resolve(dir, ["--no-task", "--files", "x"])).err,
    "jig: error: context: .ai/knowledge/adr/stub.md is selected but its source docs/adr.md is missing; fix the link or reject the stub\n",
  );
  const unselected = await resolve(dir, ["--no-task", "--files", "y", "--domains", "d", "--catalog"]);
  assert.equal(unselected.code, 0);
  doc(dir, "adr/stub.md", { id: "stub-1", type: "adr", status: "active", source: "docs/adr.md" });
  assert.match((await resolve(dir, ["--no-task", "--files", "y", "--catalog"])).out, /catalog: {3}\.ai\/knowledge\/adr\/stub\.md {2}\[stub-1\] missing source: docs\/adr\.md/);
});

test("selectors are checked: stage, globals, conflicts, unknown words", async (t) => {
  const dir = knowledgeProject(t);
  const fails = async (args: string[], message: string): Promise<void> => {
    const r = await resolve(dir, args);
    assert.deepEqual([r.code, r.out, r.err], [1, "", `jig: error: ${message}\n`], args.join(" "));
  };
  await fails(["--stage", "nope"], "context: invalid stage: nope");
  await fails(["--topics"], "context: --topics requires a value");
  await fails(["--bogus"], "context: unknown argument: --bogus");
  await fails(["--task", "a", "--no-task"], "context: --task conflicts with --no-task");
  await fails(["--task", "NOPE"], "context: unknown task: NOPE");
  fs.rmSync(path.join(dir, ".ai/knowledge/RULES.md"));
  await fails(["--no-task"], "context: missing or unreadable mandatory global: .ai/knowledge/RULES.md; restore project knowledge");
});

test("files come from stdin; the task supplies its domains; a task's resolve lists its workspace", async (t) => {
  const dir = knowledgeProject(t);
  doc(dir, "features/a.md", { id: "a", type: "feature", status: "active", paths: ["a.php"] });
  doc(dir, "features/d.md", { id: "d", type: "feature", status: "active", load: "domain", domains: ["pay"] });
  task(dir, "t1", { status: "active", branch: "elsewhere", domains: "pay" });
  const r = await resolve(dir, ["--task", "t1", "--files", "-"], {}, "a.php\n");
  assert.equal(
    r.out,
    `${GLOBALS}required:  .ai/knowledge/features/a.md  (paths: a.php)\nrequired:  .ai/knowledge/features/d.md  (domains: pay)\nworkspace: .ai/workspace/tasks/t1/task.md\n`,
  );
});

test("the cache is written for a task, served while nothing changed, and dropped when a document or a selector changes", async (t) => {
  const dir = knowledgeProject(t, undefined, true);
  doc(dir, "features/a.md", { id: "a", type: "feature", status: "active", paths: ["x"] });
  task(dir, "t1", { status: "active", branch: "elsewhere" });
  const file = path.join(dir, ".ai/workspace/tasks/t1/context-cache");
  const first = await resolve(dir, ["--task", "t1", "--files", "x"]);
  const text = fs.readFileSync(file, "utf8");
  assert.match(text, /^rule=domain-or-paths;stage-only\nstage=\nfiles=x\ndomains=\ntopics=\nids=\nall=0\n[0-9a-f]{40}\n=== rows ===\n\.ai\/knowledge\/features\/a\.md\tpaths: x\n$/);
  // a cache that still matches is served: poison its rows and see them come back
  fs.writeFileSync(file, text.replace("paths: x", "paths: cached"));
  assert.match((await resolve(dir, ["--task", "t1", "--files", "x"])).out, /\(paths: cached\)/);
  // another selector: recomputed
  assert.match((await resolve(dir, ["--task", "t1", "--files", "x", "--all"])).out, /\(paths: x\)/);
  // a document added: recomputed
  fs.writeFileSync(file, text.replace("paths: x", "paths: cached"));
  doc(dir, "features/b.md", { id: "b", type: "feature", status: "active", paths: ["x"] });
  assert.equal((await resolve(dir, ["--task", "t1", "--files", "x"])).out.includes("cached"), false);
  assert.equal(first.code, 0);
  // no task, no cache
  await resolve(dir, ["--no-task", "--files", "x"]);
  assert.equal(fs.existsSync(path.join(dir, ".ai/workspace/tasks/none")), false);
});

test("the cache is not written into a workspace that is not this repository's own", async (t) => {
  const dir = knowledgeProject(t);
  task(dir, "t1", { status: "active", branch: "elsewhere" });
  const outside = path.join(path.dirname(dir), `${path.basename(dir)}-planted`);
  fs.mkdirSync(path.join(outside, "t1"), { recursive: true });
  t.after(() => fs.rmSync(outside, { recursive: true, force: true }));
  fs.copyFileSync(path.join(dir, ".ai/workspace/tasks/t1/state"), path.join(outside, "t1/state"));
  fs.rmSync(path.join(dir, ".ai/workspace/tasks"), { recursive: true });
  fs.symlinkSync(outside, path.join(dir, ".ai/workspace/tasks"));
  const r = await resolve(dir, ["--task", "t1", "--files", "x"]);
  assert.equal(r.code, 0);
  assert.equal(fs.existsSync(path.join(outside, "t1/context-cache")), false);
});

test("queue lines follow the context; a pause asked of the task is honoured only for a named task entering a stage", async (t) => {
  const dir = knowledgeProject(t);
  task(dir, "t1", { status: "active", branch: "main", created_at: "2026-01-01", updated_at: "2026-01-01" });
  write(dir, ".ai/runtime/queue", "# jig queue 1 — written by `jig queue` only; do not edit by hand\nitem\ttask:t1\t-\t100\t-\nrequest\ttask:t1\tpause\t2026-11-27T14:00:00Z\tstandup\n");
  const plain = await resolve(dir, ["--files", "x", "--stage", "implement"]);
  assert.equal(plain.code, 0);
  assert.match(plain.out, /queue: {5}1 of 1 on the top level, no priority\nqueue: {5}pause requested 3 min ago \(standup\); honoured/);
  const paused = await resolve(dir, ["--task", "t1", "--stage", "implement", "--files", "x"]);
  assert.equal(paused.code, 4);
  assert.equal(
    paused.out,
    "paused: t1 (pause requested at 2026-11-27T14:00:00Z: standup); stage implement not entered\n" +
      "next:      a person asked for this pause; do not start the implement stage, end the session; jig task resume t1 continues the task\n",
  );
  const state = fs.readFileSync(path.join(dir, ".ai/workspace/tasks/t1/state"), "utf8");
  assert.match(state, /^status: active\nbranch: main\npaused: true\npaused_at: 2026-11-27\npaused_reason: pause requested at 2026-11-27T14:00:00Z: standup\ncreated_at: 2026-01-01\nupdated_at: 2026-11-27\n$/);
  assert.equal(
    fs.readFileSync(path.join(dir, ".ai/runtime/queue"), "utf8"),
    "# jig queue 1 — written by `jig queue` only; do not edit by hand\nitem\ttask:t1\t-\t100\t-\n",
  );
  // the request is gone and the task is paused: the next entry resolves normally
  const again = await resolve(dir, ["--task", "t1", "--stage", "implement", "--files", "x"]);
  assert.equal(again.code, 0);
});

test("a pause is not honoured without a stage, and an already paused task goes on", async (t) => {
  const dir = knowledgeProject(t);
  task(dir, "t1", { status: "active", branch: "other", paused: "true" });
  write(dir, ".ai/runtime/queue", "# jig queue 1 — x\nrequest\ttask:t1\tpause\t2026-11-27T14:00:00Z\t\n");
  assert.equal((await resolve(dir, ["--task", "t1", "--files", "x"])).code, 0);
  assert.equal((await resolve(dir, ["--task", "t1", "--stage", "plan", "--files", "x"])).code, 0);
  assert.match(fs.readFileSync(path.join(dir, ".ai/runtime/queue"), "utf8"), /request\ttask:t1/);
});

test("linked documents: a neighbour's task and spec, unreachable links with why, a link back to itself, and changes since acknowledged", async (t) => {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(fs.realpathSync(path.dirname(knowledgeProject(t))), "jig-links-")));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const dir = knowledgeProject(t);
  const nb = path.join(path.dirname(dir), path.basename(base), "nb");
  write(nb, ".ai/workspace/tasks/n1/task.md", "# n1\n");
  write(nb, ".ai/workspace/tasks/n1/plan.md", "# plan\n");
  write(nb, ".ai/specs/sp/spec.md", "# sp\n");
  const rel = path.relative(dir, nb);
  task(dir, "t1", { status: "active", branch: "other" });
  write(
    dir,
    ".ai/workspace/tasks/t1/task.md",
    `# t1\nLinked: ${rel}#n1\nLinked: ${rel}#spec/sp\nLinked: ${rel}#nope\nLinked: nowhere#x\nLinked: bad\nLinked: .#t1\n`,
  );
  const r = await resolve(dir, ["--task", "t1", "--files", "x"]);
  const linked = r.out.split("\n").filter((l) => l.startsWith("linked:"));
  assert.deepEqual(linked, [
    `linked:    ${nb}/.ai/workspace/tasks/n1/task.md  (${rel}#n1)`,
    `linked:    ${nb}/.ai/workspace/tasks/n1/plan.md  (${rel}#n1)`,
    `linked:    ${nb}/.ai/specs/sp/spec.md  (${rel}#spec/sp)`,
    `linked:    ${rel}#nope  unreachable: no task nope in ${nb} (a task workspace exists only in the clone that filed it)`,
    `linked:    nowhere#x  unreachable: no repository at ${dir}/nowhere`,
    "linked:    bad  unreachable: malformed link: no # between the repository and the id; the form is <repo>#<task-id> or <repo>#spec/<spec-id>",
    "linked:    .#t1  unreachable: this is the task itself",
  ]);
  // a ledger that holds another hash for a linked document says it changed
  write(dir, ".ai/workspace/tasks/t1/context", `${"0".repeat(40)}\t${nb}/.ai/workspace/tasks/n1/plan.md\n`);
  const changed = await resolve(dir, ["--task", "t1", "--files", "x"]);
  assert.match(changed.out, /plan\.md {2}\(.*#n1; changed since acknowledged\)/);
  assert.doesNotMatch(changed.out, /task\.md {2}\(.*changed/);
});
