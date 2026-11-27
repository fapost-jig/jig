// The clone's revision (adr-20261016-the-clone-revision-is-a-claimed-name): one counter per clone,
// raised by every Jig write and reported by every --json read. Its value is the highest numeric name
// in the revision directory; raising it claims the next name by an exclusive create, so of two
// writers that saw <n> exactly one makes <n+1>.
//
// A function-for-function port of next/go/internal/storage/revision.go, which ports bash's
// scripts/lib/common.sh (jig_revision_dir, _jig_revision_scan, jig_claim_file, jig_revision_read,
// _jig_revision_clear, jig_revision_bump): all three implementations raise and read one counter.
//
// This module imports only node:* and the clock's type: src/cli/run.ts reads the counter for its
// error envelope, and the launcher runs the sources straight from a checkout, where node_modules
// is not guaranteed. Nothing here may pull in zod or yaml, directly or through another module.
//
// Not ported: bash's jig_task_state_forget (an in-process cache of the state read) has no
// counterpart, since nothing here caches; and jig_record_changed's second half, the redraw of the
// status page, because neither skeleton has a status page.

import fs from "node:fs";
import path from "node:path";
import type { Clock } from "../clock.ts";

/** How far below a claim a name must be before a raise clears it (_JIG_REV_KEEP). */
const KEEP = 16;
/** Claims tried before a raise gives up (bash's `tries -lt 64`). */
const TRIES = 64;

/** The first line of a small text file, or undefined when it cannot be read. */
function firstLine(file: string): string | undefined {
  try {
    return fs.readFileSync(file, "utf8").split("\n", 1)[0] as string;
  } catch {
    return undefined;
  }
}

function isDir(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/** The git directory a worktree's `.git` file names, or undefined when root/.git is not such a file. */
function gitdirOf(root: string): string | undefined {
  const line = firstLine(path.join(root, ".git"));
  if (line === undefined || !line.startsWith("gitdir: ")) return undefined;
  const gitdir = line.slice("gitdir: ".length);
  if (gitdir === "") return undefined;
  const abs = path.isAbsolute(gitdir) ? gitdir : path.join(root, gitdir);
  return isDir(abs) ? abs : undefined;
}

/** The directory gitdir's `commondir` file names, through symlinks (`cd` then `pwd -P`). */
function commondirOf(gitdir: string): string | undefined {
  const line = firstLine(path.join(gitdir, "commondir"));
  if (line === undefined || line === "") return undefined;
  try {
    return fs.realpathSync.native(path.isAbsolute(line) ? line : path.join(gitdir, line));
  } catch {
    return undefined;
  }
}

/** The main checkout of the clone root belongs to (_jig_config_clone_root_find); root itself otherwise. */
function cloneRoot(root: string): string {
  const gitdir = gitdirOf(root);
  if (gitdir === undefined) return root;
  const common = commondirOf(gitdir);
  if (common === undefined || path.basename(common) !== ".git") return root;
  return path.dirname(common);
}

/** The clone's git common directory when it is not named `.git` (jig_config_odd_common). */
function oddCommon(root: string): string | undefined {
  const gitdir = gitdirOf(root);
  if (gitdir === undefined) return undefined;
  let here: string;
  if (fs.existsSync(path.join(gitdir, "commondir"))) {
    const common = commondirOf(gitdir);
    if (common === undefined) return undefined;
    here = common;
  } else {
    try {
      here = fs.realpathSync.native(gitdir);
    } catch {
      return undefined;
    }
  }
  return path.basename(here) === ".git" ? undefined : here;
}

/**
 * Where the counter of the clone that project `root` belongs to lives (jig_revision_dir): under the
 * git common directory when that is not named `.git`, else under the main checkout's
 * `.ai/runtime/revision`. Read from git's own files, never by running git.
 */
export function revisionDir(root: string): string {
  const common = oddCommon(root);
  if (common !== undefined) return path.join(common, "jig", "revision");
  return path.join(cloneRoot(root), ".ai", "runtime", "revision");
}

/** A name of digits only is a name of the counter; anything else is not. */
function revisionNumber(name: string): number | undefined {
  if (!/^[0-9]+$/.test(name)) return undefined;
  const n = Number(name);
  return Number.isSafeInteger(n) ? n : undefined;
}

interface Scan {
  readonly highest: number | undefined;
  /** The other numeric names. */
  readonly others: string[];
}

/**
 * _jig_revision_scan: the highest numeric name in `dir` and the others. A name is a file (a claim)
 * or a directory (the counter of the first, rename-based version); either counts.
 */
function scan(dir: string): Scan {
  let names: string[];
  try {
    names = fs.readdirSync(dir).sort();
  } catch {
    return { highest: undefined, others: [] };
  }
  let highest: number | undefined;
  let highName = "";
  const others: string[] = [];
  for (const name of names) {
    const n = revisionNumber(name);
    if (n === undefined) continue;
    if (highest === undefined) {
      highest = n;
      highName = name;
    } else if (n > highest) {
      others.push(highName);
      highest = n;
      highName = name;
    } else {
      others.push(name);
    }
  }
  return { highest, others };
}

/** The clone's revision; 0 when Jig has written nothing in it yet (jig_revision_read). */
export function revisionRead(root: string): number {
  return scan(revisionDir(root)).highest ?? 0;
}

/** jig_claim_file: create `file`, empty, only if nothing is there; true when this process created it. */
function claimFile(file: string): boolean {
  try {
    fs.closeSync(fs.openSync(file, "wx"));
    return true;
  } catch {
    return false;
  }
}

/** _jig_revision_clear: remove the names below `below`, at most 16, best effort. */
function clear(dir: string, below: number, names: readonly string[]): void {
  let count = 0;
  for (const name of names) {
    const n = revisionNumber(name);
    if (n === undefined || n >= below) continue;
    if (count >= KEEP) break;
    count++;
    const p = path.join(dir, name);
    try {
      if (fs.statSync(p).isDirectory()) fs.rmdirSync(p);
      else fs.unlinkSync(p);
    } catch {
      // A leftover is clutter, never a wrong answer: a reader takes the highest name.
    }
  }
}

export interface RevisionRaise {
  readonly raised: boolean;
  /** Set when not raised: what bash's jig_warn says. The write the raise follows has landed regardless. */
  readonly warning?: string;
}

/**
 * jig_revision_bump: raise the clone's revision by one after a write landed. A first write claims
 * the current time in seconds rather than 1, so a revision a consumer still holds from before a lost
 * `.ai/runtime` does not come round again. A claim that loses reads again; a claim that finds the
 * highest name more than KEEP above it was made stale by a stall, and is withdrawn and made again.
 * Never throws: a counter that cannot be raised is reported in the result (Go's
 * ErrRevisionNotRaised), and the write is not undone.
 */
export function revisionBump(root: string, clock: Clock): RevisionRaise {
  const dir = revisionDir(root);
  try {
    fs.mkdirSync(dir, { recursive: true });
  } catch {
    return { raised: false, warning: `could not raise the clone revision: cannot create ${dir}` };
  }
  for (let tries = 0; tries < TRIES; tries++) {
    const { highest, others } = scan(dir);
    let next: number;
    if (highest === undefined) {
      next = clock.epoch();
    } else {
      next = highest + 1;
      others.push(String(highest));
    }
    const name = path.join(dir, String(next));
    if (!claimFile(name)) continue;
    const high = scan(dir).highest ?? next;
    if (high <= next + KEEP) {
      if (next > KEEP) clear(dir, next - KEEP, others);
      return { raised: true };
    }
    // Stale: `next` had been claimed and cleared before. Withdraw it.
    try {
      fs.unlinkSync(name);
    } catch {
      // Gone already, or not ours to remove: the loop reads again either way.
    }
  }
  return { raised: false, warning: `could not raise the clone revision in ${dir}; a reader may miss this change` };
}
