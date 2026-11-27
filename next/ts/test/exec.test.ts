import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import type { ExecCmd } from "../src/core/exec.ts";
import { exec, fakeExec, git, text } from "../src/core/exec.ts";
import { JigError } from "../src/core/errors.ts";
import { cleanEnv, ctxFor, makeProject, proc, tmpDir } from "./helpers.ts";

test("fakeExec answers by exact argv and logs every call", async () => {
  const fake = fakeExec([{ cmd: "git", args: ["status"], stdout: "clean\n" }, { cmd: "gh", args: ["pr", "list"], code: 1, stderr: "no" }]);
  const a = await fake.exec("git", ["status"]);
  assert.equal(text(a.stdout), "clean\n");
  assert.equal(a.code, 0);
  const b = await fake.exec("gh", ["pr", "list"], { cwd: "/x" });
  assert.equal(b.code, 1);
  assert.equal(text(b.stderr), "no");
  assert.deepEqual(
    fake.calls.map((c) => [c.cmd, ...c.args]),
    [["git", "status"], ["gh", "pr", "list"]],
  );
});

test("fakeExec throws on a call it was not given, and still logs it", async () => {
  const fake = fakeExec([{ cmd: "git", args: ["status"] }]);
  await assert.rejects(fake.exec("git", ["status", "--short"]), /unexpected call: git status --short/);
  assert.equal(fake.calls.length, 1);
});

test("git prepends the fsmonitor switch and -C <dir>", async () => {
  const fake = fakeExec([{ cmd: "git", args: ["-c", "core.fsmonitor=false", "-C", "/repo", "rev-parse", "HEAD"], stdout: "abc\n" }]);
  const r = await git({ exec: fake.exec }, "/repo", ["rev-parse", "HEAD"]);
  assert.equal(text(r.stdout), "abc\n");
});

test("only git, gh and glab can be started", async () => {
  await assert.rejects(exec("sh" as ExecCmd, ["-c", "true"]), (e: unknown) => e instanceof JigError && /not a program Jig starts/.test(e.message));
});

test("a missing program is a refusal, not a crash", async () => {
  const saved = process.env["PATH"];
  process.env["PATH"] = "/nonexistent";
  try {
    await assert.rejects(exec("glab", ["version"]), (e: unknown) => e instanceof JigError && /cannot run glab/.test(e.message));
  } finally {
    process.env["PATH"] = saved;
  }
});

test("real git: stdout and stderr are bytes, an exit status is returned, a name that is not UTF-8 survives", async (t) => {
  const dir = makeProject(tmpDir(t));
  const ctx = ctxFor(dir);
  const ok = await git(ctx, dir, ["rev-parse", "--show-toplevel"]);
  assert.equal(ok.code, 0);
  assert.ok(Buffer.isBuffer(ok.stdout));
  assert.equal(fs.realpathSync(text(ok.stdout).trim()), dir);

  const bad = await git(ctx, dir, ["rev-parse", "--verify", "no-such-ref"]);
  assert.notEqual(bad.code, 0);
  assert.ok(bad.stderr.length > 0);

  // A file name with a byte that is not UTF-8 (when the file system allows one).
  const odd = Buffer.concat([Buffer.from("odd-"), Buffer.from([0xff, 0xfe]), Buffer.from(".txt")]);
  try {
    fs.writeFileSync(Buffer.concat([Buffer.from(dir + path.sep), odd]), "x");
  } catch {
    return t.skip("this file system takes no non-UTF-8 names");
  }
  const ls = await git(ctx, dir, ["ls-files", "--others", "--exclude-standard", "-z"]);
  assert.ok(ls.stdout.includes(Buffer.from([0xff, 0xfe])), "the raw bytes are in stdout");
});

test("real git: the location variables of the environment are not passed on", async (t) => {
  const dir = makeProject(tmpDir(t));
  const other = makeProject(tmpDir(t));
  const before = process.env["GIT_DIR"];
  process.env["GIT_DIR"] = path.join(other, ".git");
  try {
    const r = await git(ctxFor(dir), dir, ["rev-parse", "--show-toplevel"]);
    assert.equal(r.code, 0);
    assert.equal(fs.realpathSync(text(r.stdout).trim()), dir);
  } finally {
    if (before === undefined) delete process.env["GIT_DIR"];
    else process.env["GIT_DIR"] = before;
  }
});

test("real git: the input is written to the child's stdin", async (t) => {
  const dir = makeProject(tmpDir(t));
  const r = await git(ctxFor(dir), dir, ["hash-object", "--stdin"], { input: "hello\n" });
  assert.equal(text(r.stdout).trim(), proc("git", ["hash-object", "--stdin"], { cwd: dir, env: cleanEnv(), input: "hello\n" }).stdout.trim());
});
