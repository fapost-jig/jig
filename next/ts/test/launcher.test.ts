import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { cleanEnv, proc, repoRoot, tmpDir } from "./helpers.ts";

const launcher = path.join(repoRoot, "scripts", "jig-next-ts");

test("the launcher is executable, starts with a node shebang, and has a Windows companion with LF endings", () => {
  assert.ok(fs.statSync(launcher).mode & 0o100, "executable bit");
  assert.equal(fs.readFileSync(launcher, "utf8").split("\n")[0], "#!/usr/bin/env node");
  const cmd = fs.readFileSync(`${launcher}.cmd`, "utf8");
  assert.equal(cmd, '@node "%~dp0jig-next-ts" %*\n');
});

test("a Node that is too old is told so, and nothing else runs", (t) => {
  const dir = tmpDir(t);
  const preload = path.join(dir, "old.cjs");
  fs.writeFileSync(preload, `Object.defineProperty(process.versions, "node", { value: "22.17.9" });\n`);
  const r = proc(process.execPath, ["--require", preload, launcher, "--version"], { env: cleanEnv() });
  assert.equal(r.code, 1);
  assert.equal(r.stdout, "");
  assert.equal(r.stderr, "jig: error: Node 22.18 or later is needed, found 22.17.9\n");
});

test("versions that strip types are let through, the others are not", (t) => {
  const dir = tmpDir(t);
  const outcome = (version: string): number => {
    const preload = path.join(dir, `v${version}.cjs`);
    fs.writeFileSync(preload, `Object.defineProperty(process.versions, "node", { value: "${version}" });\n`);
    return proc(process.execPath, ["--require", preload, launcher, "--version"], { env: cleanEnv() }).code;
  };
  for (const old of ["18.20.0", "20.11.0", "22.0.0", "22.17.9", "23.0.0", "23.5.9"]) assert.equal(outcome(old), 1, old);
  for (const fine of ["22.18.0", "22.99.0", "23.6.0", "24.0.0", "26.9.0"]) assert.equal(outcome(fine), 0, fine);
});

test("jig.mjs beside the launcher wins over the source, in a package of either module type", (t) => {
  for (const type of ["commonjs", "module"]) {
    const dir = tmpDir(t);
    fs.copyFileSync(launcher, path.join(dir, "jig-next-ts"));
    fs.writeFileSync(path.join(dir, "package.json"), JSON.stringify({ type }));
    fs.writeFileSync(path.join(dir, "jig.mjs"), `console.log("bundled", process.argv.slice(2).join(" "));\n`);
    const r = proc(process.execPath, [path.join(dir, "jig-next-ts"), "a", "b"], { cwd: dir, env: cleanEnv() });
    assert.equal(r.stderr, "");
    assert.equal(r.stdout, "bundled a b\n", type);
  }
});

test("with neither the bundle nor the source it says so, without a stack trace", (t) => {
  const dir = tmpDir(t);
  fs.copyFileSync(launcher, path.join(dir, "jig-next-ts"));
  const r = proc(process.execPath, [path.join(dir, "jig-next-ts"), "--version"], { cwd: dir, env: cleanEnv() });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /^jig: error: jig-next-ts: neither jig\.mjs nor next\/ts\/src\/cli\/main\.ts was found beside /);
  assert.doesNotMatch(r.stderr, /\n\s+at /);
});

test("run through a symlink it finds the real file's neighbours", (t) => {
  const dir = tmpDir(t);
  const link = path.join(dir, "jig-next-ts");
  try {
    fs.symlinkSync(launcher, link);
  } catch {
    return t.skip("no symlinks here");
  }
  const r = proc(process.execPath, [link, "--version"], { cwd: dir, env: cleanEnv() });
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /^jig \d+\.\d+\.\d+/);
});

test("the launcher prints what scripts/jig prints for --version, and refuses a bad JIG_NOW the same way", () => {
  const ts = proc(process.execPath, [launcher, "--version"], { cwd: repoRoot, env: cleanEnv() });
  const sh = proc("bash", [path.join(repoRoot, "scripts", "jig"), "--version"], { cwd: repoRoot, env: cleanEnv() });
  assert.equal(ts.code, sh.code);
  assert.equal(ts.stdout, sh.stdout);
  const tsBad = proc(process.execPath, [launcher, "--version"], { cwd: repoRoot, env: cleanEnv({ JIG_NOW: "abc" }) });
  const shBad = proc("bash", [path.join(repoRoot, "scripts", "jig"), "--version"], { cwd: repoRoot, env: cleanEnv({ JIG_NOW: "abc" }) });
  assert.equal(tsBad.code, shBad.code);
  assert.equal(tsBad.stdout, shBad.stdout);
  assert.equal(tsBad.stderr, shBad.stderr);
});
