// The module boundaries, held by looking at what src/ imports. No linter: one test, no dependency.

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { packageRoot } from "./helpers.ts";

const src = path.join(packageRoot, "src");

export interface Import {
  readonly file: string; // relative to src/, with forward slashes
  readonly spec: string;
}

function walk(dir: string, out: string[] = []): string[] {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith(".ts")) out.push(p);
  }
  return out;
}

/** Every module specifier a source text imports, exports from, dynamically imports or requires. */
export function specifiers(text: string): string[] {
  const code = text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`])\/\/.*$/gm, "$1");
  const found: string[] = [];
  const patterns = [
    /\bimport\s+(?:type\s+)?(?:[\w*${},\s]+\s+from\s+)?["']([^"']+)["']/g,
    /\bexport\s+(?:type\s+)?(?:[\w*${},\s]+)\s+from\s+["']([^"']+)["']/g,
    /\bimport\(\s*["']([^"']+)["']\s*\)/g,
    /\brequire\(\s*["']([^"']+)["']\s*\)/g,
  ];
  for (const re of patterns) for (const m of code.matchAll(re)) found.push(m[1] as string);
  return found;
}

function allImports(): Import[] {
  const out: Import[] = [];
  for (const file of walk(src)) {
    const rel = path.relative(src, file).split(path.sep).join("/");
    for (const spec of specifiers(fs.readFileSync(file, "utf8"))) out.push({ file: rel, spec });
  }
  return out;
}

/** Where a relative specifier lands, relative to src/ (empty when it leaves src/ ... only by `..`). */
function resolveRel(file: string, spec: string): string {
  return path.posix.normalize(path.posix.join(path.posix.dirname(file), spec));
}

export function violations(imports: readonly Import[]): string[] {
  const bad: string[] = [];
  for (const { file, spec } of imports) {
    const bare = spec.replace(/^node:/, "");
    const inStorage = file.startsWith("core/storage/");
    if (bare === "child_process" && file !== "core/exec.ts") bad.push(`${file}: imports ${spec}; only core/exec.ts starts processes`);
    if ((bare === "fs" || bare.startsWith("fs/")) && !inStorage) bad.push(`${file}: imports ${spec}; only core/storage/** touches the file system`);
    if (spec === "yaml" && !inStorage) bad.push(`${file}: imports yaml; only core/storage/** reads YAML`);
    if (spec.startsWith(".")) {
      const target = resolveRel(file, spec);
      if (file.startsWith("core/") && (target === "cli" || target.startsWith("cli/"))) bad.push(`${file}: the core imports the CLI (${spec})`);
      if (target.startsWith("..")) bad.push(`${file}: imports ${spec}, which leaves src/ (tools/ and test/ are not for src/)`);
    }
  }
  return bad;
}

test("src/ keeps its boundaries", () => {
  const imports = allImports();
  assert.ok(imports.length > 20, "the scan found the imports");
  assert.deepEqual(violations(imports), []);
});

test("src/ imports only node:*, zod, yaml and itself", () => {
  const strangers = allImports().filter(({ spec }) => !spec.startsWith(".") && !spec.startsWith("node:") && spec !== "zod" && spec !== "yaml");
  assert.deepEqual(strangers, []);
});

test("src/ imports with .ts extensions", () => {
  const bad = allImports().filter(({ spec }) => spec.startsWith(".") && !spec.endsWith(".ts"));
  assert.deepEqual(bad, []);
});

test("the check itself sees a violation of each rule", () => {
  const imports: Import[] = [
    { file: "core/version.ts", spec: "node:child_process" },
    { file: "cli/run.ts", spec: "node:fs" },
    { file: "core/clock.ts", spec: "fs/promises" },
    { file: "core/errors.ts", spec: "yaml" },
    { file: "core/context.ts", spec: "../cli/run.ts" },
    { file: "core/exec.ts", spec: "../../tools/bundle.ts" },
    { file: "schemas/index.ts", spec: "../../test/helpers.ts" },
  ];
  assert.equal(violations(imports).length, imports.length);
  assert.deepEqual(violations([{ file: "core/exec.ts", spec: "node:child_process" }, { file: "core/storage/state.ts", spec: "node:fs" }, { file: "core/storage/frontmatter.ts", spec: "yaml" }]), []);
});

test("the scanner reads every import form and skips comments", () => {
  const text = `
    import a from "node:path";
    import { b } from "./b.ts";
    import type { C } from "./c.ts";
    export { d } from "./d.ts";
    export * from "./e.ts";
    const x = await import("./f.ts");
    // import nope from "./commented.ts";
    /* import nope2 from "./block.ts"; */
    const s = "not an import";
  `;
  assert.deepEqual(specifiers(text).sort(), ["./b.ts", "./c.ts", "./d.ts", "./e.ts", "./f.ts", "node:path"]);
});
