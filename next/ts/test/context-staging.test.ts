// Which task is current on the staging flow: a `ready` task parked at the staging branch is no candidate
// (task_current's `_task_parked_read`). The process runner is a fake answering the refs and commits a task's branch, its
// base and origin's staging branch have; the forge cache is a real file. The last test runs bash's `jig context` on a
// scratch staging project built with the real git and compares the two, with and without a cache.

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fakeGit, git, jigContext, knowledgeProject, task, write } from "./context-helpers.ts";
import type { FakeGitOpts } from "./context-helpers.ts";
import { bashJig } from "./helpers.ts";

const B = "b".repeat(40);
const T = "1".repeat(40);
const S = "5".repeat(40);
const CONFIG = "git.base_branch: main\ngit.flow: staging\ngit.staging_branch: staging\n";

/** The refs and the walk of one task branch `tip` (parent: the base) that is, or is not, on origin's staging branch. */
function graph(onStaging: boolean, extra: Partial<FakeGitOpts> = {}): FakeGitOpts {
  const staging = (extra.refs ?? ["refs/remotes/origin/staging"]).includes("refs/remotes/origin/staging");
  return {
    branch: "task/x",
    answers: {
      ...(staging ? { "rev-parse --verify --quiet refs/remotes/origin/staging^{commit}": `${S}\n` } : {}),
      "for-each-ref --format=%(refname)\t%(objectname) refs/heads refs/remotes/origin": `refs/heads/task/x\t${T}\nrefs/remotes/origin/main\t${B}\nrefs/remotes/origin/staging\t${S}\n`,
      [`rev-list --parents ${T} ^${B}`]: `${T} ${B}\n`,
      [`rev-list ${S} ^${B}`]: onStaging ? `${S} ${B}\n${T}\n` : `${S}\n`,
    },
    ...extra,
  };
}

function project(t: { after(fn: () => void): void }, state: Record<string, string> = {}, config = CONFIG): string {
  const dir = knowledgeProject(t, config);
  task(dir, "x", { status: "ready", branch: "task/x", ...state });
  return dir;
}

async function current(dir: string, opts: FakeGitOpts): Promise<boolean> {
  const r = await jigContext(dir, ["--files", "a"], {}, "", fakeGit(dir, opts));
  assert.equal(r.code, 0, r.err);
  return r.out.includes("workspace:");
}

const cache = (dir: string, lines: string[]): void => write(dir, ".ai/runtime/forge-cache", `# a comment\n\n${lines.join("\n")}\n`);

test("a ready task whose work is on the staging branch is parked, and is no current task", async (t) => {
  const dir = project(t);
  assert.equal(await current(dir, graph(true)), false);
  assert.equal(await current(dir, graph(false)), true);
});

test("an active task is never parked; a ready task off the staging flow is a candidate", async (t) => {
  const dir = project(t, { status: "active" });
  assert.equal(await current(dir, graph(true)), true);
  const direct = project(t, {}, "git.base_branch: main\n");
  assert.equal(await current(direct, graph(true)), true);
});

test("a pull request into the base that is open or merged ends parking; one the cache says closed does not", async (t) => {
  const dir = project(t);
  cache(dir, ["task/x\tmain\topen\t-\t2026-11-12T10:00:00Z\t-\thttps://f/1\t-\t-\t-"]);
  assert.equal(await current(dir, graph(true)), true);
  cache(dir, ["task/x\tmain\tmerged\t-\t2026-11-12T10:00:00Z\t-\thttps://f/1"]);
  assert.equal(await current(dir, graph(true)), true);
  cache(dir, ["task/x\tmain\tclosed\t-\t2026-11-12T10:00:00Z\t-\thttps://f/1"]);
  assert.equal(await current(dir, graph(true)), false);
});

test("an open pull request into the staging branch parks a task that is not on staging; the newest line of the cache decides", async (t) => {
  const dir = project(t);
  cache(dir, ["task/x\tstaging\topen\t-\t2026-11-12T10:00:00Z\t-\thttps://f/2"]);
  assert.equal(await current(dir, graph(false)), false);
  cache(dir, ["task/x\tstaging\tclosed\t-\t2026-11-12T10:00:00Z\t-\thttps://f/3", "task/x\tstaging\topen\t-\t2026-11-11T10:00:00Z\t-\thttps://f/2"]);
  assert.equal(await current(dir, graph(false)), true);
});

test("the owner's links: a pull request nobody has cached counts as open when landing by pull request; a promotion link ends parking", async (t) => {
  const dir = project(t, { pr_url: "https://f/9" });
  assert.equal(await current(dir, graph(false)), false);
  const external = project(t, { pr_url: "https://f/9" }, `${CONFIG}git.staging_land: external\n`);
  assert.equal(await current(external, graph(false)), true);
  const promo = project(t, { promote_url: "https://f/8" });
  assert.equal(await current(promo, graph(true)), true);
  cache(promo, ["task/x\tmain\topen\t-\t2026-11-12T10:00:00Z\t-\thttps://f/8"]);
  assert.equal(await current(promo, graph(true)), true);
  cache(promo, ["task/x\tmain\tclosed\t-\t2026-11-12T10:00:00Z\t-\thttps://f/8"]);
  assert.equal(await current(promo, graph(true)), false);
});

test("a task a person took back for a fix, a task of an epic, and a project with no staging branch are not parked", async (t) => {
  assert.equal(await current(project(t, { park_resumed_at: "2026-11-20" }), graph(true)), true);
  const epic = project(t, { base_branch: "epic" });
  assert.equal(await current(epic, graph(true, { refs: ["refs/remotes/origin/staging"] })), true);
  assert.equal(await current(project(t), graph(true, { refs: [] })), true); // origin's staging branch is absent
  assert.equal(await current(project(t, {}, "git.base_branch: main\ngit.flow: staging\n"), graph(true)), true);
  assert.equal(await current(project(t, {}, `${CONFIG}git.staging_land: bogus\n`), graph(true)), true);
  assert.equal(await current(project(t, {}, "git.base_branch: main\ngit.flow: staging\ngit.staging_branch: main\n"), graph(true)), true);
});

test("a merge that only brings the staging branch in is not the task's own work: the task stays on staging, not behind", async (t) => {
  const M = "9".repeat(40);
  const dir = project(t);
  const g = graph(true);
  const answers = {
    ...g.answers,
    [`rev-list --parents ${T} ^${B}`]: `${T} ${M} ${S}\n${M} ${B}\n${S} ${B}\n`,
    [`rev-list ${S} ^${B}`]: `${S}\n`,
  };
  // T merges staging S into its own line M: a merge whose second parent is on staging is not own work, so T is not behind
  // but its own line M does not reach staging either, so the task is not on staging at all
  assert.equal(await current(dir, { ...g, answers }), true);
});

test("the staging walk and the cache were read once per call, with no forge asked", async (t) => {
  const dir = project(t);
  const fake = fakeGit(dir, graph(true));
  await jigContext(dir, ["--files", "a"], {}, "", fake);
  assert.equal(fake.calls.filter((c) => c.startsWith("for-each-ref")).length, 1);
  assert.equal(fake.calls.some((c) => c.includes("fetch") || c.startsWith("ls-remote")), false);
});

test("against bash: a scratch staging project, with no cache and with one (real git)", async (t) => {
  const dir = knowledgeProject(t, CONFIG, true);
  const g = (...a: string[]): void => git(dir, ...a);
  fs.appendFileSync(path.join(dir, ".git/info/exclude"), "origin.git/\n.ai/runtime/\n.ai/workspace/\n");
  g("add", "-A");
  g("commit", "-q", "-m", "snapshot");
  g("clone", "-q", "--bare", ".", "origin.git");
  g("remote", "add", "origin", path.join(dir, "origin.git"));
  g("branch", "staging");
  g("push", "-q", "origin", "main", "staging");
  for (const id of ["on", "behind", "promoted", "never"]) {
    g("checkout", "-q", "-b", `task/${id}`, "main");
    write(dir, `${id}.txt`, `${id}\n`);
    g("add", `${id}.txt`);
    g("commit", "-q", "-m", id);
  }
  g("branch", "task/fresh", "main");
  for (const id of ["on", "behind", "promoted"]) {
    g("checkout", "-q", "staging");
    g("merge", "-q", "--no-ff", "-m", `ship ${id}`, `task/${id}`);
  }
  g("push", "-q", "origin", "staging");
  g("checkout", "-q", "task/behind");
  fs.appendFileSync(path.join(dir, "behind.txt"), "fix\n");
  g("commit", "-q", "-am", "fix behind");
  g("checkout", "-q", "main");
  write(dir, "later.txt", "later\n");
  g("add", "later.txt");
  g("commit", "-q", "-m", "main moves on");
  g("push", "-q", "origin", "main");
  g("checkout", "-q", "task/promoted");
  g("merge", "-q", "--no-ff", "-m", "bring main in", "origin/main");
  g("checkout", "-q", "main");
  g("branch", "-D", "-q", "staging");
  const ids = ["on", "behind", "promoted", "never", "fresh"];
  for (const id of ids) task(dir, id, { status: "ready", branch: `task/${id}` });
  const answers = async (): Promise<string[]> => {
    const rows: string[] = [];
    for (const id of ids) {
      g("checkout", "-q", `task/${id}`);
      const port = await jigContext(dir, ["--files", "a"]);
      const bash = bashJig(dir, ["context", "--files", "a"]);
      assert.equal(bash.code, 0, bash.stderr);
      assert.equal(port.out, bash.stdout, `${id}: ${port.out} / ${bash.stdout}`);
      rows.push(`${id}:${bash.stdout.includes("workspace:")}`);
    }
    return rows;
  };
  const none = await answers();
  assert.deepEqual(none, ["on:false", "behind:true", "promoted:false", "never:true", "fresh:true"]);
  const line = (head: string, base: string, state: string, url: string): string => `${head}\t${base}\t${state}\t-\t2026-11-12T10:00:00Z\t-\t${url}\tmergeable\t-\t-`;
  write(dir, ".ai/runtime/forge-cache", `${line("task/behind", "staging", "open", "-")}\n${line("task/promoted", "main", "open", "-")}\n`);
  assert.deepEqual(await answers(), ["on:false", "behind:false", "promoted:true", "never:true", "fresh:true"]);
});
