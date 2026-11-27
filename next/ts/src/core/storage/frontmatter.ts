// The YAML frontmatter of a markdown file: the block between the first line `---` and the next.
//
// Real YAML, so the `yaml` library reads it, with the failsafe schema (every scalar a string, no
// implicit typing) and a LineCounter for the line number of an error. Interpreting the fields
// (types, paths, domains) is `jig context`, not this module.

import fs from "node:fs";
import { LineCounter, parseDocument } from "yaml";
import { JigError } from "../errors.ts";
import { Frontmatter } from "../../schemas/frontmatter.ts";

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

  const lineCounter = new LineCounter();
  const doc = parseDocument(block, { schema: "failsafe", lineCounter, uniqueKeys: true });
  const err = doc.errors[0];
  if (err) {
    const pos = err.linePos?.[0];
    const where = pos ? `${name}:${pos.line + 1}` : name; // +1: the opening `---` is line 1
    throw new JigError("failed", `${where}: invalid frontmatter: ${err.message.split("\n")[0]}`);
  }
  const value: unknown = doc.toJS();
  const parsed = Frontmatter.safeParse(value ?? {});
  if (!parsed.success) {
    throw new JigError("failed", `${name}: frontmatter is not a map of text, lists and maps`);
  }
  return { data: parsed.data, bodyLine: end + 2 };
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
