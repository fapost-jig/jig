import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import type { Metafile } from "esbuild";
import { bundleProblems, lockProblems, packageOf, packageProblems, rangeProblems, runtimeClosure } from "../tools/check-deps.ts";
import { tmpDir } from "./helpers.ts";

test("ranges, tags and wildcards in package.json are found; exact versions are not", () => {
  assert.deepEqual(rangeProblems({ dependencies: { a: "1.2.3", b: "2.0.0-rc.1" }, devDependencies: { c: "3.4.5" } }), []);
  const bad = rangeProblems({ dependencies: { a: "^1.2.3", b: "~1.0.0", c: "*", d: "latest", e: ">=1" }, devDependencies: { f: "1.x", g: "1" } });
  assert.equal(bad.length, 7);
});

test("the lockfile must exist and say what package.json says", () => {
  const pkg = { dependencies: { a: "1.0.0" }, devDependencies: { b: "2.0.0" } };
  const lock = {
    packages: {
      "": { dependencies: { a: "1.0.0" }, devDependencies: { b: "2.0.0" } },
      "node_modules/a": { version: "1.0.0" },
      "node_modules/b": { version: "2.0.0" },
    },
  };
  assert.deepEqual(lockProblems(pkg, lock), []);
  assert.deepEqual(lockProblems(pkg, undefined), ["package-lock.json is missing"]);
  const stale = { packages: { ...lock.packages, "node_modules/a": { version: "1.0.1" } } };
  assert.equal(lockProblems(pkg, stale).length, 1);
  const extra = { packages: { ...lock.packages, "": { dependencies: { a: "1.0.0", z: "1.0.0" }, devDependencies: { b: "2.0.0" } } } };
  assert.equal(lockProblems(pkg, extra).length, 1);
});

test("the package of an input path, scoped or not", () => {
  assert.equal(packageOf("node_modules/zod/v4/index.js"), "zod");
  assert.equal(packageOf("node_modules/@scope/pkg/dist/x.js"), "@scope/pkg");
  assert.equal(packageOf("node_modules/a/node_modules/b/index.js"), "b");
  assert.equal(packageOf("src/cli/main.ts"), undefined);
});

function fakeModule(dir: string, name: string, pkg: Record<string, unknown>, files: string[] = []): void {
  const d = path.join(dir, name);
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(d, "package.json"), JSON.stringify({ name, ...pkg }));
  for (const f of files) {
    fs.mkdirSync(path.dirname(path.join(d, f)), { recursive: true });
    fs.writeFileSync(path.join(d, f), "");
  }
}

test("a package with a wrong licence, a native build or an install script is refused", (t) => {
  const dir = tmpDir(t);
  fakeModule(dir, "ok", { license: "MIT" });
  fakeModule(dir, "gpl", { license: "GPL-3.0" });
  fakeModule(dir, "nolicence", {});
  fakeModule(dir, "gyp", { license: "MIT", gypfile: true });
  fakeModule(dir, "binding", { license: "ISC" }, ["binding.gyp"]);
  fakeModule(dir, "dotnode", { license: "ISC" }, ["build/Release/x.node"]);
  fakeModule(dir, "hook", { license: "ISC", scripts: { postinstall: "node x.js" } });
  assert.deepEqual(packageProblems("ok", path.join(dir, "ok")), []);
  for (const name of ["gpl", "nolicence", "gyp", "binding", "dotnode", "hook"]) {
    assert.equal(packageProblems(name, path.join(dir, name)).length, 1, name);
  }
});

test("the runtime closure follows dependencies of dependencies", (t) => {
  const dir = tmpDir(t);
  fakeModule(dir, "top", { license: "MIT", dependencies: { mid: "1.0.0" } });
  fakeModule(dir, "mid", { license: "MIT", dependencies: { leaf: "1.0.0" } });
  fakeModule(dir, "leaf", { license: "MIT" });
  assert.deepEqual(runtimeClosure({ dependencies: { top: "1.0.0" } }, dir), ["leaf", "mid", "top"]);
});

test("a bundle with a stranger inside, or an import outside node:*, is refused", (t) => {
  const dir = tmpDir(t);
  fakeModule(dir, "dep", { license: "MIT" });
  fakeModule(dir, "stranger", { license: "MIT" });
  const meta = (inputs: string[], imports: string[]): Metafile =>
    ({
      inputs: Object.fromEntries(inputs.map((i) => [i, { bytes: 1, imports: [] }])),
      outputs: { "dist/jig.mjs": { bytes: 1, inputs: {}, imports: imports.map((p) => ({ path: p, kind: "import-statement", external: true })), exports: [], entryPoint: "x" } },
    }) as unknown as Metafile;
  const pkg = { dependencies: { dep: "1.0.0" } };
  assert.deepEqual(bundleProblems(meta(["src/a.ts", "node_modules/dep/i.js"], ["node:fs"]), pkg, dir), []);
  assert.equal(bundleProblems(meta(["node_modules/stranger/i.js"], ["node:fs"]), pkg, dir).length, 1);
  assert.equal(bundleProblems(meta(["node_modules/dep/i.js"], ["node:fs", "left-pad"]), pkg, dir).length, 1);
});
