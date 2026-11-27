// The frontmatter of a document as bash's line reader gives it (scripts/lib/frontmatter.sh: `_fm_scan_v`, `fm_get_block_v`,
// `fm_list_block_v`): the fallback for a document the YAML reader refuses. A port reads any file 0.51.2 reads exactly as
// 0.51.2 does and never refuses it for a value 0.51.2 accepts; this reader is how `jig context` keeps that rule for
// knowledge documents (`Text with: a colon`, a duplicate key, an unclosed inline list, a non-map value).

import type { Frontmatter } from "../../schemas/frontmatter.ts";

const SPACE = " \t\n\v\f\r";

function trim(s: string): string {
  let i = 0;
  let j = s.length;
  while (i < j && SPACE.includes(s[i] as string)) i++;
  while (j > i && SPACE.includes(s[j - 1] as string)) j--;
  return s.slice(i, j);
}

function unquote(s: string): string {
  return s.length >= 2 && s.startsWith('"') && s.endsWith('"') ? s.slice(1, -1) : s;
}

export interface Scanned {
  /** The raw lines between the opening `---` and the first closing one (to the end of the file when none closes it). */
  readonly block: string;
  /** Whether the file starts with a `---` line and has a closing one (bash's `fm_has`). */
  readonly closed: boolean;
}

/** `_fm_scan_v`: the block of a text; trailing blank lines never get in, a carriage return ends no line. */
export function scanBlock(text: string): Scanned | undefined {
  const parts = text.split("\n");
  if (parts[parts.length - 1] === "") parts.pop();
  const lines = parts.map((l) => (l.endsWith("\r") ? l.slice(0, -1) : l));
  if (lines[0] !== "---") return undefined;
  const kept: string[] = [];
  let blanks = 0;
  let closed = false;
  for (const line of lines.slice(1)) {
    if (line === "---") {
      closed = true;
      break;
    }
    if (line === "") {
      blanks++;
      continue;
    }
    for (; blanks > 0; blanks--) kept.push("");
    kept.push(line);
  }
  return { block: kept.join("\n"), closed };
}

/** `fm_get_block_v`: the trimmed scalar of `key`, quotes and a trailing `# comment` removed; empty for an absent key or a list. */
export function getScalar(block: string, key: string): string {
  const needle = `\n${key}:`;
  const at = `\n${block}`.indexOf(needle);
  if (at < 0) return "";
  const rest = `\n${block}`.slice(at + needle.length);
  let val = rest.includes("\n") ? rest.slice(0, rest.indexOf("\n")) : rest;
  const hash = val.indexOf("#");
  if (hash >= 0) val = val.slice(0, hash);
  val = trim(val);
  if (val === "" || val.startsWith("[")) return "";
  return unquote(val);
}

/**
 * `fm_list_block_v`: the items of `key`, inline `[a, b]` or block `  - a`. An inline list anywhere under the key wins
 * over a block list; of several, the first that closes its `]` is read. An inline item keeps a `#` and an empty one is
 * dropped; a block item ends at its `#`.
 */
export function getList(block: string, key: string): string[] {
  if (block === "") return [];
  let inline = false;
  let content = "";
  let closed = false;
  let capture = 0;
  const items: string[] = [];
  for (const line of block.split("\n")) {
    let rest = "";
    if (line.startsWith(`${key}:`)) {
      rest = trim(line.slice(key.length + 1));
      if (rest.startsWith("[")) {
        inline = true;
        if (!closed && rest.includes("]")) {
          closed = true;
          content = rest.slice(1, rest.lastIndexOf("]"));
        }
      }
    }
    if (capture === 0) {
      if (line.startsWith(`${key}:`) && (rest === "" || rest.startsWith("#"))) capture = 1;
    } else if (capture === 1) {
      if (line.startsWith("  - ")) {
        let item = line.slice(4);
        const hash = item.indexOf("#");
        if (hash >= 0) item = item.slice(0, hash);
        items.push(unquote(trim(item)));
      } else {
        capture = 2;
      }
    }
  }
  if (!inline) return items;
  return content
    .split(",")
    .map((i) => unquote(trim(i)))
    .filter((i) => i !== "");
}

const SCALAR_KEYS = ["id", "type", "status", "load", "source", "summary"];
const LIST_KEYS = ["paths", "domains", "topics", "stages", "requires"];

/** The fields `jig context` reads of a document, as bash reads them, in the shape the YAML reader answers with. */
export function bashFields(block: string): Frontmatter {
  const data: Frontmatter = {};
  for (const k of SCALAR_KEYS) {
    const v = getScalar(block, k);
    if (v !== "") data[k] = v;
  }
  for (const k of LIST_KEYS) {
    const v = getList(block, k);
    if (v.length > 0) data[k] = v;
  }
  return data;
}
