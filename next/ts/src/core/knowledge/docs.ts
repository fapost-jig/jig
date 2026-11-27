// The knowledge documents `jig context` considers, and what it reads for each.

import type { Ctx } from "../context.ts";
import { die } from "../errors.ts";
import { GLOBAL_DOCS, documentFrontmatter, knowledgeFiles, sourceReadable } from "../storage/knowledge.ts";
import type { Frontmatter } from "../../schemas/frontmatter.ts";
import { commaWords, pathMatchesAny, statusResolvable } from "./match.ts";

type RootCtx = Pick<Ctx, "root">;

/** `jig_knowledge_docs`: every document under `.ai/knowledge` that can carry frontmatter (the three globals do not), root-relative, sorted. */
export function knowledgeDocs(ctx: RootCtx): string[] {
  const globals = new Set(GLOBAL_DOCS.map((g) => `.ai/knowledge/${g}`));
  return knowledgeFiles(ctx).filter((f) => !globals.has(f));
}

/** `fm_get`: a scalar's text; empty for an absent key or a list. */
export function scalar(data: Frontmatter, key: string): string {
  const v = data[key];
  return typeof v === "string" ? v : "";
}

/** `fm_list`: the items of a list, empty ones dropped; nothing for an absent key or a scalar. */
export function list(data: Frontmatter, key: string): string[] {
  const v = data[key];
  if (!Array.isArray(v)) return [];
  return v.filter((i): i is string => typeof i === "string" && i !== "");
}

/**
 * `_ctx_doc_reason_v`: `paths: <glob>` or `domains: <domain>` for the first entry that matches (the
 * `paths` list is asked before `domains`), or undefined when neither does.
 */
export function docReason(data: Frontmatter, files: readonly string[], haveFiles: boolean, domains: readonly string[]): string | undefined {
  if (haveFiles) {
    for (const item of list(data, "paths")) if (pathMatchesAny(item, files)) return `paths: ${item}`;
  }
  if (domains.length > 0) {
    for (const item of list(data, "domains")) if (domains.includes(item)) return `domains: ${item}`;
  }
  return undefined;
}

/**
 * `_ctx_read_path`: what the agent reads for a selected document: its own path, or the source of a stub.
 * Refuses when the source is not a regular file inside the repository.
 */
export function readPath(ctx: RootCtx, doc: string, source: string): string {
  if (source === "") return doc;
  if (!sourceReadable(ctx, source)) {
    throw die(`context: ${doc} is selected but its source ${source} is missing; fix the link or reject the stub`);
  }
  return source;
}

export interface MatchedDoc {
  readonly path: string;
  readonly reason: string;
}

/**
 * `_ctx_matched_docs`: one row per document that matches the files or the domains, sorted by row text.
 * `all` lifts the status rule. A document that is `load: stage` is never listed here.
 */
export function matchedDocs(ctx: RootCtx, files: readonly string[], haveFiles: boolean, domainsArg: string, all: boolean): MatchedDoc[] {
  const domains = commaWords(domainsArg);
  const rows: MatchedDoc[] = [];
  for (const doc of knowledgeDocs(ctx)) {
    const fm = documentFrontmatter(ctx, doc);
    if (fm === undefined) continue;
    const data = fm.data;
    if (scalar(data, "load") === "stage") continue;
    if (!all && !statusResolvable(scalar(data, "status"))) continue;
    let reason = docReason(data, files, haveFiles, domains);
    if (reason === undefined) continue;
    const source = scalar(data, "source");
    const shown = readPath(ctx, doc, source);
    if (source !== "") reason = `${reason}; linked by ${scalar(data, "id")}`;
    rows.push({ path: shown, reason });
  }
  return rows;
}
