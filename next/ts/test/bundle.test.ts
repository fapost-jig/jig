import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { bundle, declaredJigVersion } from "../tools/bundle.ts";
import { bundleProblems } from "../tools/check-deps.ts";
import type { Metafile } from "esbuild";
import { bashJig, cleanEnv, packageRoot, proc, repoRoot } from "./helpers.ts";

/** A scratch directory inside dist/ (ignored by git), so that a bundle there still finds the framework above it. */
function scratch(t: { after(fn: () => void): void }): string {
  const dir = fs.mkdtempSync(path.join(fs.mkdirSync(path.join(packageRoot, "dist"), { recursive: true }) ?? path.join(packageRoot, "dist"), ".test-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function importsOf(text: string): string[] {
  return [...text.matchAll(/(?:^|[;\s])(?:import|export)\s[^"'`;]*?from\s*["']([^"']+)["']|\bimport\(\s*["']([^"']+)["']\s*\)/g)].map((m) => (m[1] ?? m[2]) as string);
}

test("the bundle prints the version as the dev run and bash do, and imports nothing but node:*", async (t) => {
  const dir = scratch(t);
  const { outfile } = await bundle(dir);
  const text = fs.readFileSync(outfile, "utf8");
  assert.equal(text.split("\n")[0], "#!/usr/bin/env node");
  const imports = importsOf(text);
  assert.ok(imports.length > 0);
  for (const spec of imports) assert.ok(spec.startsWith("node:"), `imports ${spec}`);

  const bundled = proc(process.execPath, [outfile, "--version"], { env: cleanEnv() });
  const dev = proc(process.execPath, [path.join(packageRoot, "src", "cli", "main.ts"), "--version"], { env: cleanEnv() });
  assert.equal(bundled.code, 0, bundled.stderr);
  assert.equal(bundled.stdout, dev.stdout);
  assert.equal(bundled.stdout, bashJig(repoRoot, ["--version"]).stdout);
});

test("away from any framework directory the bundle prints the version baked into it", async (t) => {
  const dir = scratch(t);
  const { outfile } = await bundle(dir);
  const away = fs.mkdtempSync(path.join(os.tmpdir(), "jig-ts-away-"));
  t.after(() => fs.rmSync(away, { recursive: true, force: true }));
  fs.copyFileSync(outfile, path.join(away, "jig.mjs"));
  const r = proc(process.execPath, [path.join(away, "jig.mjs"), "--version"], { cwd: away, env: cleanEnv() });
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, `jig ${declaredJigVersion()}\n`);
});

test("zod and yaml bundle, load and run from the bundle", async (t) => {
  const dir = scratch(t);
  const probe = path.join(dir, "probe.ts");
  fs.writeFileSync(
    probe,
    `import { loadYaml, parseFrontmatter } from "../../src/core/storage/frontmatter.ts";
import { TaskState, JsonEnvelope } from "../../src/schemas/index.ts";
import { configValue } from "../../src/core/storage/flat.ts";
await loadYaml();
const fm = parseFrontmatter("---\\nid: x\\nlist: [a, b]\\n---\\nbody");
console.log(JSON.stringify({
  fm: fm?.data,
  state: TaskState.safeParse({ task_id: "a", status: "active" }).success,
  badState: TaskState.safeParse({ task_id: ".a" }).success,
  envelope: JsonEnvelope.safeParse({ schema: 1, revision: 0, generated_at: "2026-09-21T14:13:20Z", data: {} }).success,
  cfg: configValue("a.b: c # d\\n", "a.b"),
}));
`,
  );
  const out = path.join(dir, "out");
  fs.mkdirSync(out);
  const { outfile, metafile } = await bundle(out, { entry: probe });
  const text = fs.readFileSync(outfile, "utf8");
  // yaml is CommonJS and requires the built-in `process`: without the bundle's own `require` this run dies with "Dynamic require of".
  for (const spec of importsOf(text)) assert.ok(spec.startsWith("node:"), `imports ${spec}`);
  const r = proc(process.execPath, [outfile], { env: cleanEnv() });
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(JSON.parse(r.stdout), {
    fm: { id: "x", list: ["a", "b"] },
    state: true,
    badState: false,
    envelope: true,
    cfg: "c",
  });
  const names = new Set(Object.keys(metafile.inputs).filter((i) => i.includes("node_modules/")).map((i) => i.split("node_modules/")[1]?.split("/")[0]));
  assert.ok(names.has("zod") && names.has("yaml"), `bundled packages: ${[...names].join(", ")}`);
  const pkg = JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"), "utf8")) as Parameters<typeof bundleProblems>[1];
  assert.deepEqual(bundleProblems(metafile as Metafile, pkg, path.join(packageRoot, "node_modules")), []);
});

test("the bundle is readable: original names of the context code and a marker for each of its modules", async (t) => {
  const dir = scratch(t);
  const { outfile } = await bundle(dir);
  const text = fs.readFileSync(outfile, "utf8");
  for (const name of ["statelessContext", "requiredRows", "acknowledge", "resolveContext", "recordCheckout", "cancelPauseRequest"]) {
    assert.match(text, new RegExp(`function ${name}\\(`), `${name} keeps its name`);
  }
  for (const marker of ["src/core/context/stateless.ts", "src/core/context/required.ts", "src/core/context/ledger.ts", "src/cli/context.ts"]) {
    assert.ok(text.includes(`// ${marker}\n`), `a marker for ${marker}`);
  }
  assert.ok(text.split("\n").length > 10000, "the bundle is not squeezed into a few lines");
});
