import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { exec } from "../src/core/exec.ts";
import { systemClock } from "../src/core/clock.ts";
import { jigVersion, releaseVersion } from "../src/core/version.ts";
import { bashJig, cleanEnv, proc, repoRoot, tmpDir } from "./helpers.ts";

const ctx = { root: "/", exec, clock: systemClock({}), env: {} };

/** A framework checkout in a temporary directory: scripts/ copied, skills/ and templates/ made, no git yet. */
function framework(t: { after(fn: () => void): void }): string {
  const dir = tmpDir(t);
  fs.cpSync(path.join(repoRoot, "scripts"), path.join(dir, "scripts"), { recursive: true });
  fs.mkdirSync(path.join(dir, "skills"));
  fs.mkdirSync(path.join(dir, "templates"));
  return dir;
}

function git(dir: string, ...args: string[]): void {
  const r = proc("git", args, { cwd: dir, env: cleanEnv({ HOME: dir }) });
  assert.equal(r.code, 0, r.stderr);
}

function declared(dir: string): string {
  const m = /^JIG_VERSION="([^"]+)"/m.exec(fs.readFileSync(path.join(dir, "scripts", "lib", "version.sh"), "utf8"));
  return m?.[1] ?? "";
}

async function both(dir: string, env: Record<string, string> = {}): Promise<{ ts: string; sh: string }> {
  const sh = proc("bash", [path.join(dir, "scripts", "jig"), "--version"], { cwd: dir, env: cleanEnv({ HOME: dir, ...env }) });
  assert.equal(sh.code, 0, sh.stderr);
  return { ts: `jig ${await jigVersion(ctx, path.join(dir, "scripts", "lib"))}\n`, sh: sh.stdout };
}

test("a release tag number is three digit fields", () => {
  assert.equal(releaseVersion("v1.2.3"), "1.2.3");
  for (const bad of ["1.2.3", "v1.2", "v1.2.3.4", "v1.2.3-rc1", "v1..3", "v.1.2", "v1.2.3+x", ""]) assert.equal(releaseVersion(bad), undefined, bad);
});

test("--version of this checkout equals bash's", async () => {
  const sh = bashJig(repoRoot, ["--version"]);
  assert.equal(`jig ${await jigVersion(ctx, path.join(repoRoot, "scripts", "lib"))}\n`, sh.stdout);
});

test("through .ai/scripts, the link of a link-mode project, the version is the checkout's", async () => {
  const via = path.join(repoRoot, ".ai", "scripts", "lib");
  assert.equal(await jigVersion(ctx, via), await jigVersion(ctx, path.join(repoRoot, "scripts", "lib")));
});

test("a checkout with commits past its tag is X.Y.Z+<sha>, at the tag X.Y.Z, without git X.Y.Z+unknown; bash agrees", async (t) => {
  const dir = framework(t);
  const x = declared(dir);

  const unknown = await both(dir);
  assert.equal(unknown.ts, `jig ${x}+unknown\n`);
  assert.equal(unknown.ts, unknown.sh);

  git(dir, "init", "-q", "-b", "main", ".");
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "release");
  const sha = proc("git", ["rev-parse", "--short=7", "HEAD"], { cwd: dir, env: cleanEnv() }).stdout.trim();
  const past = await both(dir);
  assert.equal(past.ts, `jig ${x}+${sha}\n`);
  assert.equal(past.ts, past.sh);

  git(dir, "tag", "-a", `v${x}`, "-m", `v${x}`);
  const at = await both(dir);
  assert.equal(at.ts, `jig ${x}\n`);
  assert.equal(at.ts, at.sh);

  // A tag of another version does not make HEAD a release.
  git(dir, "tag", "-d", `v${x}`);
  git(dir, "tag", "v99.0.0");
  const other = await both(dir);
  assert.equal(other.ts, `jig ${x}+${sha}\n`);
  assert.equal(other.ts, other.sh);
});

test("a copy inside somebody else's repository is not a checkout of its own", async (t) => {
  const outer = tmpDir(t);
  git(outer, "init", "-q", "-b", "main", ".");
  const dir = path.join(outer, "vendor", "jig");
  fs.mkdirSync(dir, { recursive: true });
  fs.cpSync(path.join(repoRoot, "scripts"), path.join(dir, "scripts"), { recursive: true });
  fs.mkdirSync(path.join(dir, "skills"));
  fs.mkdirSync(path.join(dir, "templates"));
  const { ts, sh } = await both(dir);
  assert.equal(ts, `jig ${declared(dir)}+unknown\n`);
  assert.equal(ts, sh);
});

test("an installed copy (no skills/ or templates/) prints the plain number, as does a checkout whose declaration is unreadable", async (t) => {
  const dir = framework(t);
  fs.rmdirSync(path.join(dir, "skills"));
  const installed = await both(dir);
  assert.equal(installed.ts, `jig ${declared(dir)}\n`);
  assert.equal(installed.ts, installed.sh);

  const odd = framework(t);
  const file = path.join(odd, "scripts", "lib", "version.sh");
  fs.appendFileSync(file, 'JIG_VERSION="7.7.7"\n');
  const twice = await both(odd);
  assert.equal(twice.ts, "jig 7.7.7\n", "two declarations: nothing is read without running it, the sourced one wins");
  assert.equal(twice.ts, twice.sh);
});
