// Jig's own files: where the framework lives and what it declares about itself.
//
// The scripts directory holds `lib/version.sh` (the declared version) and `lib/config.sh` (the list of
// keys a person's local config may answer for). Both are read as text, never run.

import fs from "node:fs";
import path from "node:path";
import { lines } from "./flat.ts";

function isFile(p: string): boolean {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

function isDir(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

export function readTextIfFile(p: string): string | undefined {
  try {
    return fs.readFileSync(p, "utf8");
  } catch {
    return undefined;
  }
}

export function realPath(p: string): string {
  return fs.realpathSync(p);
}

/**
 * The `scripts/lib` directory of the framework, found by walking up from `startDir`: the first
 * directory that holds `scripts/lib/version.sh` (a source checkout or an unpacked release) or is
 * itself a `scripts` directory holding `lib/version.sh` (a project's `.ai/scripts`).
 */
export function findScriptsLib(startDir: string): string | undefined {
  let dir = path.resolve(startDir);
  for (;;) {
    const inside = path.join(dir, "scripts", "lib");
    if (isFile(path.join(inside, "version.sh"))) return inside;
    const here = path.join(dir, "lib");
    if (path.basename(dir) === "scripts" && isFile(path.join(here, "version.sh"))) return here;
    const parent = path.dirname(dir);
    if (parent === dir) return undefined;
    dir = parent;
  }
}

/** `jig_is_source_root`: a framework source checkout has skills/, templates/ and scripts/jig. */
export function isSourceRoot(dir: string): boolean {
  return isDir(path.join(dir, "skills")) && isDir(path.join(dir, "templates")) && isFile(path.join(dir, "scripts", "jig"));
}

/**
 * `jig_declared_version`: the version a checkout declares in scripts/lib/version.sh, read without
 * running anything. Exactly one line must be shaped `JIG_VERSION="<version>"` with a value free of
 * quotes and spaces.
 */
export function declaredVersion(versionFile: string): string | undefined {
  const text = readTextIfFile(versionFile);
  if (text === undefined) return undefined;
  const found: string[] = [];
  for (const line of lines(text)) {
    const m = /^JIG_VERSION="([^" ]+)"[ \t\n\v\f\r]*$/.exec(line);
    if (m?.[1] !== undefined) found.push(m[1]);
  }
  return found.length === 1 ? found[0] : undefined;
}

/** `$JIG_VERSION` as the sourced version.sh leaves it: the last `JIG_VERSION="..."` assignment wins. */
export function loadedVersion(versionFile: string): string | undefined {
  const text = readTextIfFile(versionFile);
  if (text === undefined) return undefined;
  let value: string | undefined;
  for (const line of lines(text)) {
    const m = /^JIG_VERSION="([^"]*)"/.exec(line);
    if (m?.[1] !== undefined) value = m[1];
  }
  return value;
}

export interface LocalKeyLists {
  /** `JIG_CFG_LOCAL_KEYS`: keys the local file may answer for. */
  readonly local: ReadonlySet<string>;
  /** `JIG_CFG_LOCAL_ONLY_KEYS`: keys that answer only from the local file and the default. */
  readonly localOnly: ReadonlySet<string>;
}

function assigned(text: string, name: string): string[] {
  for (const line of lines(text)) {
    const m = new RegExp(`^${name}="([^"]*)"`).exec(line);
    if (m?.[1] !== undefined) return m[1].split(/[ \t\n]+/).filter((w) => w !== "");
  }
  return [];
}

/** The two key lists of scripts/lib/config.sh. */
export function readLocalKeyLists(configSh: string): LocalKeyLists {
  const text = readTextIfFile(configSh) ?? "";
  return {
    local: new Set(assigned(text, "JIG_CFG_LOCAL_KEYS")),
    localOnly: new Set(assigned(text, "JIG_CFG_LOCAL_ONLY_KEYS")),
  };
}
