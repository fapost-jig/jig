// The YAML frontmatter of a markdown file: the block between the first line `---` and the next.
//
// Real YAML, so the `yaml` library reads it, with the failsafe schema (every scalar a string, no
// implicit typing) and a LineCounter for the line number of an error. Interpreting the fields
// (types, paths, domains) is `jig context`, not this module.

import fs from "node:fs";
import { JigError } from "../errors.ts";
import type { Frontmatter, FrontmatterValue } from "../../schemas/frontmatter.ts";

// The YAML library is the largest thing the command line loads, and most calls never meet a document with
// frontmatter: it is imported on first need (`loadYaml`), before the synchronous readers below are used.
type YamlModule = typeof import("yaml");
let yaml: YamlModule | undefined;

/** Load the YAML reader; every caller of `parseFrontmatter` and `readFrontmatter` awaits this first. */
export async function loadYaml(): Promise<void> {
  yaml ??= await import("yaml");
}

/** Whether a file starts with a frontmatter fence: the one question that decides if `loadYaml` is needed. */
export function startsWithFence(file: string): boolean {
  let fd: number | undefined;
  try {
    fd = fs.openSync(file, "r");
    const buf = Buffer.alloc(3);
    return fs.readSync(fd, buf, 0, 3, 0) === 3 && buf.toString("latin1") === "---";
  } catch {
    return false;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

/** The shape the failsafe schema gives: a map of strings, lists and maps (schemas/frontmatter.ts holds the same rule as a zod type). */
function isValue(v: unknown): v is FrontmatterValue {
  if (typeof v === "string") return true;
  if (Array.isArray(v)) return v.every(isValue);
  if (typeof v === "object" && v !== null) return Object.values(v).every(isValue);
  return false;
}

function isFrontmatter(v: unknown): v is Frontmatter {
  return typeof v === "object" && v !== null && !Array.isArray(v) && Object.values(v).every(isValue);
}

export interface ParsedFrontmatter {
  readonly data: Frontmatter;
  /** The line of the file where the body starts (1-based). */
  readonly bodyLine: number;
}

/** The frontmatter of `text`, or undefined when it has none. Throws `failed` naming the file and line on bad YAML. */
export function parseFrontmatter(text: string, name = "<text>"): ParsedFrontmatter | undefined {
  const all = text.split("\n").map((l) => (l.endsWith("\r") ? l.slice(0, -1) : l));
  if (all[0] !== "---") return undefined;
  const end = all.indexOf("---", 1);
  if (end < 0) return undefined;
  const block = all.slice(1, end).join("\n");

  if (yaml === undefined) throw new Error("the YAML reader is not loaded: await loadYaml() first");
  const lineCounter = new yaml.LineCounter();
  const doc = yaml.parseDocument(block, { schema: "failsafe", lineCounter, uniqueKeys: true });
  const err = doc.errors[0];
  if (err) {
    const pos = err.linePos?.[0];
    const where = pos ? `${name}:${pos.line + 1}` : name; // +1: the opening `---` is line 1
    throw new JigError("failed", `${where}: invalid frontmatter: ${err.message.split("\n")[0]}`);
  }
  const value: unknown = doc.toJS();
  const data = value ?? {};
  if (!isFrontmatter(data)) throw new JigError("failed", `${name}: frontmatter is not a map of text, lists and maps`);
  return { data, bodyLine: end + 2 };
}

export function readFrontmatter(file: string): ParsedFrontmatter | undefined {
  let text: string;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return undefined;
  }
  return parseFrontmatter(text, file);
}
