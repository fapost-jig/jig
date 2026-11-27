// The dependency rules of this package, checked rather than described (design.md, "Правила зависимостей").
// Run with `npm run check-deps`, after `npm run bundle`.
//
//  1. package.json has no version ranges: every dependency is one exact version.
//  2. package-lock.json exists and says the same as package.json.
//  3. Every package that went into the bundle, and everything a runtime dependency needs, is a runtime
//     dependency with an allowed licence and without a native part or an install script.
//  4. The bundle imports nothing but `node:*`.
//
// The native-code rule is for what lands in the bundle. esbuild is a native binary and a dev dependency:
// a build tool never reaches a project.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { Metafile } from "esbuild";

export const ALLOWED_LICENCES: readonly string[] = ["MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC"];

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");

interface PackageJson {
  dependencies?: Record<string, string>;
  devDependencies?: Record<string, string>;
  optionalDependencies?: Record<string, string>;
  peerDependencies?: Record<string, string>;
  license?: string;
  gypfile?: boolean;
  scripts?: Record<string, string>;
}

interface Lockfile {
  lockfileVersion?: number;
  packages?: Record<string, { version?: string; dependencies?: Record<string, string>; devDependencies?: Record<string, string> }>;
}

const EXACT = /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/;

/** Rule 1. */
export function rangeProblems(pkg: PackageJson): string[] {
  const bad: string[] = [];
  for (const field of ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"] as const) {
    for (const [name, spec] of Object.entries(pkg[field] ?? {})) {
      if (!EXACT.test(spec)) bad.push(`package.json: ${field}.${name} is "${spec}", not one exact version`);
    }
  }
  return bad;
}

/** Rule 2. */
export function lockProblems(pkg: PackageJson, lock: Lockfile | undefined): string[] {
  if (lock === undefined) return ["package-lock.json is missing"];
  const bad: string[] = [];
  const rootEntry = lock.packages?.[""];
  if (rootEntry === undefined) return ["package-lock.json has no root entry"];
  for (const field of ["dependencies", "devDependencies"] as const) {
    const want = pkg[field] ?? {};
    const have = rootEntry[field] ?? {};
    for (const [name, spec] of Object.entries(want)) {
      if (have[name] !== spec) bad.push(`package-lock.json: ${field}.${name} is "${have[name] ?? "absent"}", package.json says "${spec}"`);
      const locked = lock.packages?.[`node_modules/${name}`]?.version;
      if (locked !== spec) bad.push(`package-lock.json: node_modules/${name} is ${locked ?? "absent"}, package.json says ${spec}`);
    }
    for (const name of Object.keys(have)) if (!(name in want)) bad.push(`package-lock.json: ${field}.${name} is not in package.json`);
  }
  return bad;
}

/** The package a `node_modules/...` input path belongs to. */
export function packageOf(input: string): string | undefined {
  const parts = input.split("/");
  const i = parts.lastIndexOf("node_modules");
  if (i < 0) return undefined;
  const first = parts[i + 1];
  if (first === undefined) return undefined;
  if (first.startsWith("@")) return parts[i + 2] === undefined ? undefined : `${first}/${parts[i + 2]}`;
  return first;
}

function walkFiles(dir: string, visit: (file: string) => void): void {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walkFiles(p, visit);
    else visit(p);
  }
}

/** Rule 3 for one installed package. */
export function packageProblems(name: string, dir: string): string[] {
  const bad: string[] = [];
  const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8")) as PackageJson;
  if (pkg.license === undefined || !ALLOWED_LICENCES.includes(pkg.license)) {
    bad.push(`${name}: licence ${pkg.license ?? "(none)"} is not one of ${ALLOWED_LICENCES.join(", ")}`);
  }
  if (pkg.gypfile === true) bad.push(`${name}: has a native build (gypfile)`);
  for (const hook of ["preinstall", "install", "postinstall"]) {
    if (pkg.scripts?.[hook] !== undefined) bad.push(`${name}: has an install script (${hook})`);
  }
  walkFiles(dir, (file) => {
    const base = path.basename(file);
    if (base === "binding.gyp" || base.endsWith(".node")) bad.push(`${name}: has native code (${path.relative(dir, file)})`);
  });
  return bad;
}

/** Every package a runtime dependency needs, itself included. */
export function runtimeClosure(pkg: PackageJson, modulesDir: string): string[] {
  const seen = new Set<string>();
  const queue = Object.keys(pkg.dependencies ?? {});
  while (queue.length > 0) {
    const name = queue.pop();
    if (name === undefined || seen.has(name)) continue;
    seen.add(name);
    const file = path.join(modulesDir, name, "package.json");
    if (!fs.existsSync(file)) continue;
    const dep = JSON.parse(fs.readFileSync(file, "utf8")) as PackageJson;
    queue.push(...Object.keys(dep.dependencies ?? {}), ...Object.keys(dep.optionalDependencies ?? {}));
  }
  return [...seen].sort();
}

/** Rules 3 and 4 for a bundle's metafile. */
export function bundleProblems(meta: Metafile, pkg: PackageJson, modulesDir: string): string[] {
  const bad: string[] = [];
  const runtime = new Set(Object.keys(pkg.dependencies ?? {}));
  const inBundle = new Set<string>();
  for (const input of Object.keys(meta.inputs)) {
    const name = packageOf(input);
    if (name !== undefined) inBundle.add(name);
  }
  for (const name of inBundle) {
    if (!runtime.has(name)) bad.push(`${name}: is in the bundle but is not a runtime dependency (a transitive package must be named in dependencies)`);
  }
  for (const name of new Set([...inBundle, ...runtimeClosure(pkg, modulesDir)])) {
    const dir = path.join(modulesDir, name);
    if (!fs.existsSync(dir)) bad.push(`${name}: is not installed`);
    else bad.push(...packageProblems(name, dir));
  }
  for (const [out, info] of Object.entries(meta.outputs)) {
    for (const imp of info.imports) {
      if (!imp.path.startsWith("node:")) bad.push(`${out}: imports ${imp.path}, and only node:* may stay outside the bundle`);
    }
  }
  return bad;
}

function readJson<T>(file: string): T | undefined {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8")) as T;
  } catch {
    return undefined;
  }
}

export function checkAll(dir = root): string[] {
  const pkg = readJson<PackageJson>(path.join(dir, "package.json"));
  if (pkg === undefined) return ["package.json is missing"];
  const bad = [...rangeProblems(pkg), ...lockProblems(pkg, readJson<Lockfile>(path.join(dir, "package-lock.json")))];
  const meta = readJson<Metafile>(path.join(dir, "dist", "jig.meta.json"));
  if (meta === undefined) bad.push("dist/jig.meta.json is missing: run npm run bundle first");
  else bad.push(...bundleProblems(meta, pkg, path.join(dir, "node_modules")));
  return bad;
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const bad = checkAll();
  if (bad.length > 0) {
    for (const line of bad) console.error(`check-deps: ${line}`);
    process.exit(1);
  }
  console.log("check-deps: ok");
}
