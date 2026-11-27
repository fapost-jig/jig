// The ledger and its commands: acknowledge, pending, guard (tests/context.t.sh: ledger_*, acknowledge_*, guard_*, pending_*).
//
// The process runner is a fake whose `hash-object` answers the blob hashes git would give. The one test that runs the
// real git is "linked documents are tracked by absolute path, ..." (one `git hash-object` per directory of linked documents).

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { doc, jigContext, knowledgeProject, task, write } from "./context-helpers.ts";

const G = [".ai/knowledge/ARCHITECTURE.md", ".ai/knowledge/GLOSSARY.md", ".ai/knowledge/RULES.md"];

function project(t: { after(fn: () => void): void }): string {
  const dir = knowledgeProject(t);
  task(dir, "t1", { status: "active", branch: "elsewhere" });
  return dir;
}

const run = (dir: string, sub: string, args: string[], stdin = ""): ReturnType<typeof jigContext> =>
  jigContext(dir, [sub, "--task", "t1", ...args], {}, stdin);

const ledger = (dir: string): string => fs.readFileSync(path.join(dir, ".ai/workspace/tasks/t1/context"), "utf8");

test("pending lists the globals, then acknowledge clears them; the ledger holds hash, path and stage, sorted", async (t) => {
  const dir = project(t);
  const p0 = await run(dir, "pending", ["--files", "x"]);
  assert.equal(p0.out, `${G.join("\n")}\n`);
  const ack = await run(dir, "acknowledge", ["--stage", "implement", "--files", G.join(",")]);
  assert.deepEqual([ack.code, ack.out], [0, "acknowledged 3 document(s) for t1 at implement\n"]);
  const lines = ledger(dir).split("\n").filter((l) => l !== "");
  assert.deepEqual(lines, [...lines].sort());
  assert.deepEqual(lines.map((l) => l.replace(/^[0-9a-f]{40}\t/, "")).sort(), G.map((g) => `${g}\timplement`));
  assert.equal((await run(dir, "pending", ["--files", "x"])).out, "");
  const noStage = await run(dir, "acknowledge", ["--files", ".ai/knowledge/RULES.md"]);
  assert.equal(noStage.out, "acknowledged 1 document(s) for t1\n");
  assert.match(ledger(dir), /[0-9a-f]{40}\t\.ai\/knowledge\/RULES\.md\t-\n/);
});

test("a document that changed is pending again", async (t) => {
  const dir = project(t);
  await run(dir, "acknowledge", ["--files", G.join(",")]);
  fs.appendFileSync(path.join(dir, G[2] as string), "more\n");
  assert.equal((await run(dir, "pending", ["--files", "x"])).out, `${G[2] as string}\n`);
});

test("guard: lists what is owed with why on stderr and exits 1; passes with the attribution by stage", async (t) => {
  const dir = project(t);
  doc(dir, "features/a.md", { id: "a", type: "feature", status: "active", paths: ["x"] });
  const owed = await run(dir, "guard", ["--stage", "implement", "--files", "x"]);
  assert.equal(owed.code, 1);
  assert.equal(owed.out, "");
  assert.equal(
    owed.err,
    "context guard: 4 of 4 document(s) not acknowledged:\n" +
      "  .ai/knowledge/ARCHITECTURE.md  (global)\n  .ai/knowledge/GLOSSARY.md  (global)\n  .ai/knowledge/RULES.md  (global)\n  .ai/knowledge/features/a.md  (paths: x)\n" +
      "read them, then: jig context acknowledge --task t1 --stage implement --files <list>\n",
  );
  const noStage = await run(dir, "guard", ["--files", "x"]);
  assert.match(noStage.err, /read them, then: jig context acknowledge --task t1 --files <list>\n$/);
  await run(dir, "acknowledge", ["--stage", "implement", "--files", [...G, ".ai/knowledge/features/a.md"].join(",")]);
  const ok = await run(dir, "guard", ["--stage", "implement", "--files", "x"]);
  assert.deepEqual([ok.code, ok.out, ok.err], [0, "context guard: ok (4 document(s) acknowledged)\n  4 acknowledged at implement\n", ""]);
  const elsewhere = await run(dir, "guard", ["--stage", "review", "--files", "x"]);
  assert.equal(
    elsewhere.out,
    "context guard: ok (4 document(s) acknowledged)\n  4 acknowledged at implement\n  none acknowledged at review: this guard passed on acknowledgements made elsewhere\n",
  );
  // an old two-field line reads as no stage
  const text = ledger(dir).split("\n").filter((l) => l !== "").map((l) => l.replace(/\timplement$/, ""));
  write(dir, ".ai/workspace/tasks/t1/context", `${text.join("\n")}\n`);
  assert.match((await run(dir, "guard", ["--files", "x"])).out, /\n {2}4 acknowledged at no stage\n$/);
});

test("guard and pending without a task say so, or stay silent for an implicit none", async (t) => {
  const dir = knowledgeProject(t);
  const guard = await jigContext(dir, ["guard", "--no-task", "--files", "x"]);
  assert.deepEqual([guard.code, guard.out], [0, "context guard: no task workspace; nothing tracked\n"]);
  assert.equal((await jigContext(dir, ["guard", "--files", "x"])).out, "context guard: no task workspace; nothing tracked\n");
  assert.equal((await jigContext(dir, ["pending", "--no-task", "--files", "x"])).out, "context pending: no task workspace; nothing tracked\n");
  assert.equal((await jigContext(dir, ["pending", "--files", "x"])).out, "");
});

test("acknowledge: --task, --files, --stage and --revoke are checked", async (t) => {
  const dir = project(t);
  const fails = async (args: string[], message: string, stdin = ""): Promise<void> => {
    const r = await jigContext(dir, ["acknowledge", ...args], {}, stdin);
    assert.deepEqual([r.code, r.out, r.err], [1, "", `jig: error: ${message}\n`], args.join(" "));
  };
  await fails(["--files", "x"], "context acknowledge: --task is required");
  await fails(["--task", "NOPE", "--files", "x"], "context: unknown task: NOPE");
  await fails(["--task", "t1"], "context acknowledge: --files is required");
  await fails(["--task", "t1", "--files", "-"], "context acknowledge: --files is empty", "\n\n");
  await fails(["--task", "t1", "--files", "x", "--stage", "bogus"], "context: invalid stage: bogus");
  await fails(
    ["--task", "t1", "--files", "x", "--stage", "plan", "--revoke"],
    "context acknowledge: --revoke takes no --stage: a revoke withdraws the path's acknowledgement whatever stage it was made at",
  );
  await fails(["--task", "t1", "--files", "x", "--bogus"], "context: unknown argument: --bogus");
});

test("acknowledge refuses a batch naming every bad path, and records nothing", async (t) => {
  const dir = project(t);
  write(dir, "outside.md", "x\n");
  const r = await run(dir, "acknowledge", ["--files", "/etc/passwd,../x.md,nope.md,outside.md,.ai/knowledge/missing.md," + G[0]]);
  assert.equal(r.code, 1);
  assert.equal(
    r.err,
    "context acknowledge: path must be repository-relative: /etc/passwd (an absolute path only for a document a Linked: line of the task reaches)\n" +
      "context acknowledge: path may not contain '..': ../x.md\n" +
      "context acknowledge: not a knowledge document or a linked source: nope.md\n" +
      "context acknowledge: not a knowledge document or a linked source: outside.md\n" +
      "context acknowledge: no such document: .ai/knowledge/missing.md\n" +
      "jig: error: context acknowledge: 5 path(s) refused; nothing recorded. Give the paths as jig context guard prints them\n",
  );
  assert.equal(fs.existsSync(path.join(dir, ".ai/workspace/tasks/t1/context")), false);
});

test("acknowledge takes ./ and absolute project paths as the same document, once", async (t) => {
  const dir = project(t);
  const r = await run(dir, "acknowledge", ["--files", `./${G[0] as string},${dir}/${G[0] as string},${G[0] as string}`]);
  assert.equal(r.out, "acknowledged 1 document(s) for t1\n");
  assert.equal(ledger(dir).split("\n").filter((l) => l !== "").length, 1);
});

test("a source an accepted stub links is acknowledged in its place; a still proposed stub's is not", async (t) => {
  const dir = project(t);
  write(dir, "docs/adr.md", "# adr\n");
  doc(dir, "adr/stub.md", { id: "s", type: "adr", status: "accepted", source: "docs/adr.md" });
  assert.equal((await run(dir, "acknowledge", ["--files", "docs/adr.md"])).code, 0);
  doc(dir, "adr/stub.md", { id: "s", type: "adr", status: "proposed", source: "docs/adr.md" });
  assert.equal((await run(dir, "acknowledge", ["--files", "docs/adr.md"])).code, 1);
  doc(dir, "adr/stub.md", { id: "s", type: "adr", status: "accepted", source: "docs/adr.md" });
  fs.rmSync(path.join(dir, "docs/adr.md"));
  write(dir, "real.md", "r\n");
  fs.symlinkSync("real.md", path.join(dir, "docs/adr.md"));
  const swapped = await run(dir, "acknowledge", ["--files", "docs/adr.md"]);
  assert.match(swapped.err, /no such document: docs\/adr\.md/);
});

test("revoke withdraws an acknowledgement, a deleted document's too; what was never acknowledged is refused", async (t) => {
  const dir = project(t);
  await run(dir, "acknowledge", ["--stage", "plan", "--files", G.join(",")]);
  const r = await run(dir, "acknowledge", ["--revoke", "--files", G[0] as string]);
  assert.equal(r.out, "revoked 1 document(s) for t1\n");
  assert.equal(ledger(dir).includes("ARCHITECTURE"), false);
  assert.equal((await run(dir, "pending", ["--files", "x"])).out, `${G[0] as string}\n`);
  const never = await run(dir, "acknowledge", ["--revoke", "--files", G[0] as string]);
  assert.match(never.err, /not acknowledged for this task: \.ai\/knowledge\/ARCHITECTURE\.md/);
  fs.rmSync(path.join(dir, G[1] as string));
  assert.equal((await run(dir, "acknowledge", ["--revoke", "--files", G[1] as string])).code, 0);
});

test("linked documents are tracked by absolute path, acknowledged only when a link reaches them, and reopen when they change", async (t) => {
  const dir = knowledgeProject(t, undefined, true);
  const nb = path.join(path.dirname(dir), `${path.basename(dir)}-nb`);
  t.after(() => fs.rmSync(nb, { recursive: true, force: true }));
  write(nb, ".ai/workspace/tasks/up/task.md", "# up\n");
  const rel = path.relative(dir, nb);
  task(dir, "t1", { status: "active", branch: "elsewhere" });
  write(dir, ".ai/workspace/tasks/t1/task.md", `# t1\nLinked: ${rel}#up\n`);
  const linked = `${nb}/.ai/workspace/tasks/up/task.md`;
  const owed = await run(dir, "guard", ["--files", "x"]);
  assert.match(owed.err, new RegExp(`${linked.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}  \\(linked\\)`));
  assert.equal((await run(dir, "acknowledge", ["--files", "/etc/passwd"])).code, 1);
  assert.equal((await run(dir, "acknowledge", ["--files", [...G, linked].join(",")])).code, 0);
  assert.equal((await run(dir, "guard", ["--files", "x"])).code, 0);
  fs.appendFileSync(linked, "changed\n");
  assert.equal((await run(dir, "pending", ["--files", "x"])).out, `${linked}\n`);
  assert.match((await jigContext(dir, ["resolve", "--task", "t1", "--files", "x"])).out, /changed since acknowledged/);
});

test("workspace artifacts are never tracked", async (t) => {
  const dir = project(t);
  write(dir, ".ai/workspace/tasks/t1/plan.md", "p\n");
  assert.equal((await run(dir, "pending", ["--files", "x"])).out.includes("plan.md"), false);
});

test("a pause honoured for a task whose autopilot run is on writes a journal line", async (t) => {
  const dir = knowledgeProject(t);
  task(dir, "t1", { status: "active", branch: "main", autopilot: "on", created_at: "2026-01-01" });
  write(dir, ".ai/runtime/queue", "# jig queue 1 — x\nrequest\ttask:t1\tpause\t2026-11-27T14:00:00Z\twhy\n");
  const r = await jigContext(dir, ["resolve", "--task", "t1", "--stage", "plan", "--files", "x"]);
  assert.equal(r.code, 4);
  assert.equal(
    fs.readFileSync(path.join(dir, ".ai/workspace/tasks/t1/autopilot"), "utf8"),
    "2026-11-27T14:03:00Z\tpause\tplan not entered: pause requested at 2026-11-27T14:00:00Z: why\n",
  );
});
