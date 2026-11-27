import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";
import { run } from "../src/cli/run.ts";
import { JsonEnvelope } from "../src/schemas/index.ts";
import { bashJig, cleanEnv, packageRoot, proc, repoRoot } from "./helpers.ts";

async function cli(argv: string[], env: Record<string, string> = {}, extra: { baked?: string; entryDir?: string } = {}) {
  let out = "";
  let err = "";
  const code = await run({
    argv,
    env,
    cwd: repoRoot,
    entryDir: extra.entryDir ?? path.join(packageRoot, "src", "cli"),
    bakedVersion: extra.baked,
    io: { out: (s) => (out += s), err: (s) => (err += s) },
  });
  return { code, out, err };
}

test("no arguments, help, -h and --help print the usage and succeed", async () => {
  for (const argv of [[], ["help"], ["-h"], ["--help"]]) {
    const r = await cli(argv);
    assert.equal(r.code, 0);
    assert.match(r.out, /^jig — TypeScript skeleton/);
    assert.equal(r.err, "");
  }
});

test("version and --version print what bash prints", async () => {
  const sh = bashJig(repoRoot, ["--version"]);
  for (const argv of [["version"], ["--version"]]) {
    const r = await cli(argv);
    assert.equal(r.code, sh.code);
    assert.equal(r.out, sh.stdout);
  }
});

test("a version nobody can read falls back to the one baked into the bundle", async () => {
  const r = await cli(["--version"], {}, { entryDir: "/", baked: "9.9.9" });
  assert.deepEqual([r.code, r.out], [0, "jig 9.9.9\n"]);
  const none = await cli(["--version"], {}, { entryDir: "/" });
  assert.equal(none.code, 1);
  assert.match(none.err, /^jig: error: cannot tell the version/);
});

test("an unknown command and an unknown option are refused as bash refuses them", async () => {
  const r = await cli(["bogus"]);
  const sh = bashJig(repoRoot, ["bogus"]);
  assert.equal(r.code, sh.code);
  assert.equal(r.code, 1);
  assert.equal(r.out, "");
  assert.ok(r.err.endsWith("jig: error: unknown command: bogus\n"));
  assert.ok(sh.stderr.endsWith("jig: error: unknown command: bogus\n"));

  const v = await cli(["version", "foo"]);
  const shv = bashJig(repoRoot, ["version", "foo"]);
  assert.equal(v.code, shv.code);
  assert.equal(v.err, shv.stderr);
});

test("a malformed JIG_NOW is refused before any command, help included, as bash refuses it", async () => {
  for (const argv of [["help"], ["--version"], ["bogus"]]) {
    const r = await cli(argv, { JIG_NOW: "soon" });
    const sh = bashJig(repoRoot, argv, { JIG_NOW: "soon" });
    assert.equal(r.code, sh.code, argv.join(" "));
    assert.equal(r.err, sh.stderr, argv.join(" "));
    assert.equal(r.out, "");
  }
});

test("--json answers with one envelope line: the refusal, with its code", async () => {
  const r = await cli(["bogus", "--json"], { JIG_NOW: "1790000000" });
  assert.equal(r.code, 1);
  assert.equal(r.err, "");
  assert.equal(r.out.split("\n").length, 2, "one line and its newline");
  const env = JsonEnvelope.parse(JSON.parse(r.out));
  assert.deepEqual(env, {
    schema: 1,
    revision: 0,
    generated_at: "2026-09-21T14:13:20Z",
    error: { code: "usage", message: "bogus: not available in the TypeScript skeleton" },
  });
});

test("--json with a bad JIG_NOW refuses inside its envelope, as bash's json_run does", async () => {
  const r = await cli(["--version", "--json"], { JIG_NOW: "soon" });
  assert.equal(r.code, 1);
  const env = JsonEnvelope.parse(JSON.parse(r.out));
  assert.ok("error" in env);
  assert.deepEqual(env.error, { code: "usage", message: "JIG_NOW must be seconds since the epoch, got 'soon'" });
});

test("the process entry point prints the same as the function", () => {
  const r = proc(process.execPath, [path.join(packageRoot, "src", "cli", "main.ts"), "--version"], { env: cleanEnv() });
  assert.equal(r.code, 0);
  assert.equal(r.stdout, bashJig(repoRoot, ["--version"]).stdout);
});
