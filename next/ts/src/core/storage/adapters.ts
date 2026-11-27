// Where the runtime adapters are, as `_jig_checkout_adapters_dir` finds them: in the framework source the
// manifest records, else in the framework checkout this copy of Jig runs from.

import fs from "node:fs";
import path from "node:path";
import type { Ctx } from "../context.ts";
import { lines } from "./flat.ts";
import { isSourceRoot } from "./framework.ts";

function isDir(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

function isFile(p: string): boolean {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

/** `manifest_header_get`: a `key: value` line above the manifest's `---`; one leading space of the value is dropped. */
export function manifestHeader(ctx: Pick<Ctx, "root">, key: string): string | undefined {
  let text: string;
  try {
    text = fs.readFileSync(path.join(ctx.root, ".ai", "manifest"), "utf8");
  } catch {
    return undefined;
  }
  for (const raw of lines(text)) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    if (line === "---") return undefined;
    if (line.startsWith(`${key}:`)) {
      const v = line.slice(line.indexOf(":") + 1);
      return v.startsWith(" ") ? v.slice(1) : v;
    }
  }
  return undefined;
}

/** The path functions of a platform: `node:path`'s posix or win32, injected where a test stands for the other platform. */
export type PathApi = Pick<typeof path.posix, "delimiter" | "isAbsolute" | "sep" | "join" | "dirname" | "basename">;

/** The directories of a PATH value, split on the platform's delimiter (`:` or `;`). */
export function pathEntries(value: string, p: PathApi = path): string[] {
  return value.split(p.delimiter);
}

/** Whether `exe` is the dispatcher of a framework checkout, `<root>/scripts/jig`, in either separator; the root when it is. */
export function dispatcherRoot(exe: string, p: PathApi = path): string | undefined {
  const norm = exe.split(p.sep).join("/");
  return norm.endsWith("/scripts/jig") ? exe.slice(0, -"/scripts/jig".length) : undefined;
}

/** `command -v jig`: the first executable file called `jig` on PATH; a relative hit answers as bash does, non-absolute. */
function jigOnPath(env: Ctx["env"], p: PathApi): string | undefined {
  for (const entry of pathEntries(env["PATH"] ?? "", p)) {
    const candidate = p.join(entry === "" ? "." : entry, "jig");
    try {
      if (!fs.statSync(candidate).isFile()) continue;
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {
      continue;
    }
  }
  return undefined;
}

/** `jig_resolve_path`: follow a chain of links to the file, resolving each relative target against its link's directory. */
function resolveLinks(file: string, p0: PathApi): string | undefined {
  let p = file;
  for (let hops = 0; hops < 64; hops++) {
    let target: string;
    try {
      if (!fs.lstatSync(p).isSymbolicLink()) return p;
      target = fs.readlinkSync(p);
    } catch {
      return undefined;
    }
    p = p0.isAbsolute(target) ? target : p0.join(p0.dirname(p), target);
  }
  return undefined;
}

/**
 * `jig_global_source`: the framework checkout behind the `jig` the PATH selects, physical, when that is the
 * dispatcher of a framework source checkout (`.../scripts/jig` in a directory with skills/, templates/ and scripts/jig).
 */
export function globalSource(env: Ctx["env"], p: PathApi = path): string | undefined {
  const found = jigOnPath(env, p);
  if (found === undefined || !p.isAbsolute(found)) return undefined;
  const resolved = resolveLinks(found, p);
  if (resolved === undefined) return undefined;
  let dir: string;
  try {
    dir = fs.realpathSync(path.dirname(resolved));
  } catch {
    return undefined;
  }
  const root = dispatcherRoot(p.join(dir, p.basename(resolved)), p);
  return root !== undefined && isSourceRoot(root) ? root : undefined;
}

/**
 * The adapters directory this run can reach, or undefined. `lib` is the framework's `scripts/lib`.
 * The manifest's `jig.source` of `global` names the global framework (`globalSource`).
 */
export function adaptersDir(ctx: Pick<Ctx, "root" | "env">, lib: string | undefined): string | undefined {
  let src = manifestHeader(ctx, "jig.source") ?? "";
  if (src === ".") src = ctx.root;
  else if (src === "global") src = globalSource(ctx.env) ?? "";
  if (src !== "" && isDir(path.join(src, "adapters"))) return path.join(src, "adapters");
  const candidates: string[] = [];
  if (lib !== undefined) candidates.push(path.resolve(lib, "..", ".."));
  const pinned = ctx.env["JIG_SOURCE"];
  if (pinned !== undefined && pinned !== "") candidates.push(pinned);
  for (const c of candidates) {
    if (isSourceRoot(c)) return isDir(path.join(c, "adapters")) ? path.join(c, "adapters") : undefined;
  }
  return undefined;
}

/** `[ -f <adapters>/<name>/adapter.sh ]`. */
export function adapterPresent(dir: string, name: string): boolean {
  return isFile(path.join(dir, name, "adapter.sh"));
}
