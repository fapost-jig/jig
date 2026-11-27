// `.ai/knowledge`: which documents there are, and whether the file a stub links is one an agent may read.
//
// The walk is bash's `jig_knowledge_docs`: `find .ai/knowledge -type f -name '*.md' | sort` in the C
// locale, less the three global documents. The source check is `jig_knowledge_read_path_v`'s.

import fs from "node:fs";
import path from "node:path";
import type { Ctx } from "../context.ts";
import { sortBytes } from "./bytes.ts";
import { JigError } from "../errors.ts";
import { loadYaml, readFrontmatter, startsWithFence } from "./frontmatter.ts";
import { bashFields, scanBlock } from "./frontmatter-bash.ts";
import type { ParsedFrontmatter } from "./frontmatter.ts";

export const GLOBAL_DOCS: readonly string[] = ["GLOSSARY.md", "ARCHITECTURE.md", "RULES.md"];

export function knowledgeDir(ctx: Pick<Ctx, "root">): string {
  return path.join(ctx.root, ".ai", "knowledge");
}

function walk(dir: string, out: string[]): void {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    const p = `${dir}/${e.name}`;
    if (e.isDirectory()) walk(p, out);
    else if (e.isFile() && e.name.endsWith(".md")) out.push(p);
  }
}

/** Every `*.md` regular file under `.ai/knowledge` (a link is not followed), as paths relative to the root, sorted by bytes. */
export function knowledgeFiles(ctx: Pick<Ctx, "root">): string[] {
  const dir = knowledgeDir(ctx);
  const found: string[] = [];
  walk(dir, found);
  return sortBytes(found).map((p) => p.slice(ctx.root.replace(/\/$/, "").length + 1));
}

/** `[ -f path ]`: a regular file, a link to one included. `path` is relative to the root. */
export function isFileAt(ctx: Pick<Ctx, "root">, rel: string): boolean {
  try {
    return fs.statSync(path.join(ctx.root, rel)).isFile();
  } catch {
    return false;
  }
}

function isLink(p: string): boolean {
  try {
    return fs.lstatSync(p).isSymbolicLink();
  } catch {
    return false;
  }
}

/**
 * Make the frontmatter reader ready for the documents of this project: the YAML library is loaded only when some
 * document starts with a fence, so a call over a project without any never pays for it. Await before `documentFrontmatter`.
 */
export async function prepareDocuments(ctx: Pick<Ctx, "root">): Promise<void> {
  for (const rel of knowledgeFiles(ctx)) {
    if (startsWithFence(path.join(ctx.root, rel))) {
      await loadYaml();
      return;
    }
  }
}

/**
 * The frontmatter of a document (relative to the root); undefined when it has none or cannot be read. A document the YAML
 * reader refuses (bad YAML, a duplicate key, a value that is no map) is read as bash reads it, never refused: a port reads
 * any file 0.51.2 reads, exactly as 0.51.2 does.
 */
export function documentFrontmatter(ctx: Pick<Ctx, "root">, rel: string): ParsedFrontmatter | undefined {
  const file = path.join(ctx.root, rel);
  try {
    return readFrontmatter(file);
  } catch (e) {
    if (!(e instanceof JigError)) throw e;
    let text: string;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch {
      return undefined;
    }
    const scanned = scanBlock(text);
    return scanned === undefined || !scanned.closed ? undefined : { data: bashFields(scanned.block), bodyLine: 0 };
  }
}

/**
 * The tail of `jig_knowledge_read_path_v`: whether `src`, the `source:` of a stub, is a regular file
 * inside the repository. A path that could leave it, a link, or a file reached through a linked
 * directory that leads out is not.
 */
export function sourceReadable(ctx: Pick<Ctx, "root">, src: string): boolean {
  if (src.startsWith("/") || src.startsWith("../") || src.includes("/../") || src.endsWith("..")) return false;
  const full = path.join(ctx.root, src);
  if (!isFileAt(ctx, src) || isLink(path.join(ctx.root, src))) return false;
  const parts = src.split("/");
  let dir = "";
  let linked = false;
  for (let i = 0; i < parts.length - 1; i++) {
    dir = dir === "" ? (parts[i] as string) : `${dir}/${parts[i] as string}`;
    if (isLink(path.join(ctx.root, dir))) {
      linked = true;
      break;
    }
  }
  if (!linked) return true;
  try {
    const physRoot = fs.realpathSync(ctx.root);
    const phys = fs.realpathSync(path.dirname(full));
    return `${phys}/`.startsWith(`${physRoot}/`);
  } catch {
    return false;
  }
}
