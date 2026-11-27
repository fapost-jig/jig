// The documents a call is required to have read (`_ctx_required_rows`): the load policy and the selectors,
// the ids named, the transitive `requires` closure, and the cache that spares the work the next call
// of the same selectors against the same knowledge. Shared by `resolve`, `pending` and `guard`.

import path from "node:path";
import type { JigCtx } from "../context.ts";
import { die } from "../errors.ts";
import { hashList } from "../git/hash.ts";
import { list, readPath, scalar } from "../knowledge/docs.ts";
import { knowledgeDocs } from "../knowledge/docs.ts";
import { pathMatchesAny, statusResolvable } from "../knowledge/match.ts";
import { byteCompare } from "../storage/bytes.ts";
import { isFile, readText, writeViaTemp } from "../storage/files.ts";
import { documentFrontmatter, prepareDocuments } from "../storage/knowledge.ts";
import { taskDir } from "../storage/state-read.ts";
import { workspaceGuardPasses } from "../task/workspace.ts";
import type { Frontmatter } from "../../schemas/frontmatter.ts";
import type { Selectors } from "./selectors.ts";

/** A row of the required set: a document's repository-relative path and why it is required. */
export interface Row {
  readonly path: string;
  readonly reason: string;
}

export interface ActiveDoc {
  readonly path: string;
  readonly data: Frontmatter;
}

/** `_ctx_active_docs`: the documents with frontmatter that are not retired, unless `--all`. Walk order. */
export function activeDocs(ctx: JigCtx, all: boolean): ActiveDoc[] {
  const out: ActiveDoc[] = [];
  for (const rel of knowledgeDocs(ctx)) {
    const fm = documentFrontmatter(ctx, rel);
    if (fm === undefined) continue;
    if (!all && !statusResolvable(scalar(fm.data, "status"))) continue;
    out.push({ path: rel, data: fm.data });
  }
  return out;
}

/** The words of a space-separated selector. */
export function words(s: string): string[] {
  return s.split(/[ \t\n]+/).filter((w) => w !== "");
}

function filesOf(s: Selectors): string[] {
  return s.files.split("\n");
}

/**
 * `_ctx_select_reason`: why the document's body is required, or undefined. `load` defaults to `matched`; a
 * `matched` document is not selected by a domain alone (that is the catalog's), and `load: stage` is selected by
 * the stage alone.
 */
export function selectReason(data: Frontmatter, s: Selectors): string | undefined {
  const load = scalar(data, "load") || "matched";
  const domains = words(s.domains);
  const stages = list(data, "stages");
  if (load === "stage") {
    return s.stage !== "" && stages.includes(s.stage) ? `load: stage; stage: ${s.stage}` : undefined;
  }
  if (load === "always") return "load: always";
  const byPaths = (): string | undefined => {
    if (s.files === "") return undefined;
    for (const g of list(data, "paths")) if (pathMatchesAny(g, filesOf(s))) return `paths: ${g}`;
    return undefined;
  };
  if (load === "domain") {
    if (s.domains !== "") {
      for (const d of list(data, "domains")) if (domains.includes(d)) return `domains: ${d}`;
    }
    return byPaths();
  }
  const p = byPaths();
  if (p !== undefined) return p;
  if (s.topics !== "") {
    const topics = words(s.topics);
    for (const t of list(data, "topics")) if (topics.includes(t)) return `topics: ${t}`;
  }
  if (s.stage !== "" && s.domains !== "" && load === "matched" && stages.includes(s.stage)) {
    for (const d of list(data, "domains")) if (domains.includes(d)) return `stage: ${s.stage}; domain: ${d}`;
  }
  return undefined;
}

// --- the cache ---------------------------------------------------------------------

const CACHE_MARK = "=== rows ===";

function cacheFile(ctx: JigCtx, id: string): string {
  return path.join(taskDir(ctx, id), "context-cache");
}

/**
 * `_ctx_cache_fingerprint`: one block standing for "resolution would come out the same": the selection rule's
 * name, every selector, and the content hash of every knowledge document.
 */
export async function cacheFingerprint(ctx: JigCtx, s: Selectors): Promise<string> {
  const docs = knowledgeDocs(ctx);
  const hashes = await hashList(ctx, ctx.root, docs);
  return (
    `rule=domain-or-paths;stage-only\nstage=${s.stage}\nfiles=${s.files}\ndomains=${s.domains}\ntopics=${s.topics}\nids=${s.ids}\nall=${s.all ? 1 : 0}\n` +
    hashes.map((h) => `${h}\n`).join("")
  );
}

function chomp(s: string): string {
  return s.replace(/\n+$/, "");
}

function rowLines(rows: readonly Row[]): string {
  return rows.map((r) => `${r.path}\t${r.reason}\n`).join("");
}

function parseRows(text: string): Row[] {
  const out: Row[] = [];
  for (const line of text.split("\n")) {
    if (line === "") continue;
    const tab = line.indexOf("\t");
    out.push(tab < 0 ? { path: line, reason: "" } : { path: line.slice(0, tab), reason: line.slice(tab + 1) });
  }
  return out;
}

/** `_ctx_cache_read`: the cached rows when the fingerprint still matches; undefined otherwise. */
async function cacheRead(ctx: JigCtx, s: Selectors): Promise<Row[] | undefined> {
  const file = cacheFile(ctx, s.task);
  if (!isFile(file)) return undefined;
  const text = readText(file);
  if (text === undefined) return undefined;
  const lines = text.split("\n");
  const mark = lines.indexOf(CACHE_MARK);
  const head = mark < 0 ? text : lines.slice(0, mark).join("\n");
  if (chomp(head) !== chomp(await cacheFingerprint(ctx, s))) return undefined;
  if (mark < 0) return [];
  return parseRows(lines.slice(mark + 1).join("\n"));
}

/** `_ctx_cache_write`: only into a workspace that is this repository's own. */
async function cacheWrite(ctx: JigCtx, s: Selectors, rows: readonly Row[]): Promise<void> {
  if (!(await workspaceGuardPasses(ctx, s.task, "context"))) return;
  const body = `${await cacheFingerprint(ctx, s)}${CACHE_MARK}\n${rowLines(rows)}`;
  writeViaTemp(cacheFile(ctx, s.task), body);
}

// --- the rows ----------------------------------------------------------------------

/** `_ctx_check_selected_sources`: dies on the first required stub whose source is missing. */
export function checkSelectedSources(ctx: JigCtx, rows: readonly Row[]): void {
  for (const r of rows) {
    const fm = documentFrontmatter(ctx, r.path);
    readPath(ctx, r.path, fm === undefined ? "" : scalar(fm.data, "source"));
  }
}

/** `_ctx_close_requires`: add the transitive `requires` closure; a requirement that resolves to nothing is fatal. */
function closeRequires(ctx: JigCtx, rows: Row[], idmap: ReadonlyMap<string, string>): void {
  let added = true;
  while (added) {
    added = false;
    for (const r of [...rows]) {
      const fm = documentFrontmatter(ctx, r.path);
      if (fm === undefined) continue;
      const id = scalar(fm.data, "id");
      for (const req of list(fm.data, "requires")) {
        const doc = idmap.get(req);
        if (doc === undefined) throw die(`context: ${r.path} requires unknown or inactive document: ${req}; run: jig knowledge check`);
        if (rows.some((x) => x.path === doc)) continue;
        rows.push({ path: doc, reason: `requires: ${id}` });
        added = true;
      }
    }
  }
}

/**
 * `_ctx_required_rows`: a row for every required document, sorted. Served from the task's cache when the
 * selectors and every document are as they were; recomputed, and cached for a named or current task, otherwise.
 */
export async function requiredRows(ctx: JigCtx, s: Selectors): Promise<Row[]> {
  await prepareDocuments(ctx);
  if (s.task !== "") {
    const cached = await cacheRead(ctx, s);
    if (cached !== undefined) {
      checkSelectedSources(ctx, cached);
      return cached;
    }
  }
  const active = activeDocs(ctx, s.all);
  const rows: Row[] = [];
  for (const d of active) {
    const reason = selectReason(d.data, s);
    if (reason !== undefined) rows.push({ path: d.path, reason });
  }
  const idmap = new Map<string, string>();
  for (const d of active) {
    const id = scalar(d.data, "id");
    if (id !== "" && !idmap.has(id)) idmap.set(id, d.path);
  }
  for (const id of words(s.ids)) {
    const doc = idmap.get(id);
    if (doc === undefined) throw die(`context: no active document with id: ${id}`);
    if (rows.some((x) => x.path === doc)) continue;
    rows.push({ path: doc, reason: `id: ${id}` });
  }
  closeRequires(ctx, rows, idmap);
  rows.sort((a, b) => byteCompare(`${a.path}\t${a.reason}`, `${b.path}\t${b.reason}`));
  checkSelectedSources(ctx, rows);
  if (s.task !== "") await cacheWrite(ctx, s, rows);
  return rows;
}
