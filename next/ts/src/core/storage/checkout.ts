// What a checkout records about itself under the clone's gitignored `.ai/runtime/`
// (adr-20260924-a-checkout-records-what-is-happening-in-it): the files, as bash's checkout.sh reads
// and writes them. Every function here gives up quietly, as the recorder does: a record that
// cannot be written must never fail the command.

import fs from "node:fs";
import path from "node:path";
import type { Ctx } from "../context.ts";
import { cloneRoot } from "./revision.ts";
import { sortBytes } from "./bytes.ts";

export function runtimeDir(ctx: Pick<Ctx, "root">): string {
  return path.join(ctx.root, ".ai", "runtime");
}

/** Where the clone's records of taken tasks live: `<clone root>/.ai/runtime/taken`. */
export function takenDir(ctx: Pick<Ctx, "root">): string {
  return path.join(cloneRoot(ctx.root), ".ai", "runtime", "taken");
}

export function isDirectory(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

export function isRegularFile(p: string): boolean {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

/** `mkdir -p`; false when it cannot. */
export function ensureDir(p: string): boolean {
  try {
    fs.mkdirSync(p, { recursive: true });
    return true;
  } catch {
    return false;
  }
}

/**
 * `_jig_checkout_read`: the first `<key>: <value>` line of a flat record, a carriage return stripped;
 * undefined when the file or the line is missing.
 */
export function recordValue(file: string, key: string): string | undefined {
  let text: string;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return undefined;
  }
  const prefix = `${key}: `;
  for (const raw of text.split("\n")) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    if (line.startsWith(prefix)) return line.slice(prefix.length);
  }
  return undefined;
}

/** The lines of a record, each without its carriage return (a last line with no newline included). */
export function recordLines(file: string): string[] {
  let text: string;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return [];
  }
  const parts = text.split("\n");
  if (parts[parts.length - 1] === "") parts.pop();
  return parts.map((l) => (l.endsWith("\r") ? l.slice(0, -1) : l));
}

/** `_jig_checkout_write`: a temporary beside the file with a leading dot, then a rename. */
export function writeRecord(file: string, body: string): boolean {
  const tmp = path.join(path.dirname(file), `.tmp.${path.basename(file)}.${process.pid}`);
  try {
    fs.writeFileSync(tmp, body);
    fs.renameSync(tmp, file);
    return true;
  } catch {
    try {
      fs.rmSync(tmp, { force: true });
    } catch {
      // nothing to do
    }
    return false;
  }
}

/** The mtime of a file in whole seconds, or undefined. */
export function mtimeSeconds(file: string): number | undefined {
  try {
    return Math.floor(fs.statSync(file).mtimeMs / 1000);
  } catch {
    return undefined;
  }
}

/** The taken records of one session: `<taken>/<task>/<session>` for every task directory that holds one, in glob order. */
export function takenRecordsOf(ctx: Pick<Ctx, "root">, session: string): string[] {
  const base = takenDir(ctx);
  let names: string[];
  try {
    names = fs.readdirSync(base);
  } catch {
    return [];
  }
  const out: string[] = [];
  for (const name of sortBytes(names.filter((n) => !n.startsWith(".")))) {
    const f = path.join(base, name, session);
    if (isRegularFile(f)) out.push(f);
  }
  return out;
}
