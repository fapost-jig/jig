// The context ledger and the commands over it (ctx_acknowledge, ctx_pending, ctx_guard in scripts/lib/context.sh;
// ADR-0015): one line per acknowledged document, `<git-hash><TAB><path>[<TAB><stage>]`, in the task's gitignored
// workspace. What it proves is narrow: the agent said it read the document.

import path from "node:path";
import type { JigCtx, Output } from "../context.ts";
import { die } from "../errors.ts";
import { hashPaths, isAbsolutePath } from "../git/hash.ts";
import { knowledgeDocs, scalar } from "../knowledge/docs.ts";
import { statusResolvable } from "../knowledge/match.ts";
import { byteCompare, sortBytes } from "../storage/bytes.ts";
import { isFile, isSymlink, physicalDir, writeViaTemp } from "../storage/files.ts";
import { stateFile, taskDir, validTaskId } from "../storage/state-read.ts";
import { documentFrontmatter, prepareDocuments } from "../storage/knowledge.ts";
import { workspaceRoot } from "../task/workspace.ts";
import { ledgerLines, linkedDocs } from "./linked.ts";
import { globalPaths, readRows } from "./resolve.ts";
import { requiredRows } from "./required.ts";
import type { Row } from "./required.ts";
import type { Selectors } from "./selectors.ts";

export interface AcknowledgeOptions {
  readonly task: string;
  readonly filesArg: string;
  readonly filesStdin: boolean;
  /** The stage given, or "" for none. */
  readonly stage: string;
  readonly revoke: boolean;
}

function ledgerFile(ctx: JigCtx, id: string): string {
  return path.join(taskDir(ctx, id), "context");
}

/** `_ctx_normalise_path_v`: the path as guard and resolve print it. */
function normalisePath(ctx: JigCtx, given: string, linked: readonly string[]): string {
  let p = given;
  while (p.startsWith("./")) p = p.slice(2);
  if (!isAbsolutePath(p)) return p;
  if (linked.includes(p)) return p;
  if (p.startsWith(`${ctx.root}/`)) return p.slice(ctx.root.length + 1);
  const dir = path.dirname(p);
  const base = path.basename(p);
  const phys = physicalDir(dir);
  if (phys !== undefined && `${phys}/`.startsWith(`${ctx.root}/`)) {
    const rest = phys.slice(ctx.root.length).replace(/^\//, "");
    return rest !== "" ? `${rest}/${base}` : base;
  }
  return p;
}

/** `_ctx_is_linked_source`: whether a resolvable stub links `want`. */
function isLinkedSource(ctx: JigCtx, want: string): boolean {
  for (const doc of knowledgeDocs(ctx)) {
    const fm = documentFrontmatter(ctx, doc);
    if (fm === undefined || scalar(fm.data, "source") !== want) continue;
    if (statusResolvable(scalar(fm.data, "status"))) return true;
  }
  return false;
}

const ABSOLUTE = (rel: string): string =>
  `path must be repository-relative: ${rel} (an absolute path only for a document a Linked: line of the task reaches)`;

/** `_ctx_check_knowledge_path`: what is wrong with a path to acknowledge, or undefined. */
function knowledgePathProblem(ctx: JigCtx, rel: string, linked: readonly string[]): string | undefined {
  if (isAbsolutePath(rel)) {
    if (linked.includes(rel)) return undefined;
    return ABSOLUTE(rel);
  }
  if (rel.includes("..")) return `path may not contain '..': ${rel}`;
  const full = path.join(ctx.root, rel);
  if (!(rel.startsWith(".ai/knowledge/") && rel.endsWith(".md"))) {
    if (!isLinkedSource(ctx, rel)) return `not a knowledge document or a linked source: ${rel}`;
    if (!isFile(full) || isSymlink(full)) return `no such document: ${rel}`;
    const root = physicalDir(ctx.root);
    const dir = physicalDir(path.dirname(full));
    if (dir === undefined || root === undefined) return `no such document: ${rel}`;
    if (!`${dir}/`.startsWith(`${root}/`)) return `linked source leaves the repository: ${rel}`;
  }
  if (!isFile(full)) return `no such document: ${rel}`;
  return undefined;
}

/** `_ctx_check_revoked_path`: the shape check for a path whose acknowledgement is withdrawn. */
function revokedPathProblem(rel: string, have: readonly string[]): string | undefined {
  if (isAbsolutePath(rel)) {
    if (!have.includes(rel)) return ABSOLUTE(rel);
  } else if (rel.includes("..")) {
    return `path may not contain '..': ${rel}`;
  }
  if (!have.includes(rel)) return `not acknowledged for this task: ${rel}`;
  return undefined;
}

/** `IFS=<tab> read -r hash rel rest`: runs of tabs separate; the rest keeps its inner tabs. */
function splitLedgerLine(line: string): { hash: string; rel: string; rest: string } {
  let s = line.replace(/^\t+/, "");
  const take = (): string => {
    const i = s.indexOf("\t");
    if (i < 0) {
      const all = s;
      s = "";
      return all;
    }
    const f = s.slice(0, i);
    s = s.slice(i).replace(/^\t+/, "");
    return f;
  };
  const hash = take();
  const rel = take();
  return { hash, rel, rest: s.replace(/[ \t]+$/, "") };
}

/** `ctx_acknowledge`: record documents the agent says it read, or withdraw such a record. A batch is all or nothing. */
export async function acknowledge(ctx: JigCtx, o: AcknowledgeOptions, stdin: () => Promise<string>, out: Output): Promise<void> {
  if (o.task === "") throw die("context acknowledge: --task is required");
  const { task } = o;
  if (!validTaskId(task)) throw die(`invalid task id: ${task}`);
  if (!isFile(stateFile(ctx, task))) throw die(`context: unknown task: ${task}`);
  await workspaceRoot(ctx, task, "context acknowledge");

  let files: string;
  if (o.filesStdin) files = (await stdin()).replace(/\n+$/, "");
  else if (o.filesArg !== "") files = o.filesArg.replaceAll(",", "\n");
  else throw die("context acknowledge: --files is required");
  const given = files.split("\n").filter((l) => l !== "");
  if (given.length === 0) throw die("context acknowledge: --files is empty");

  await prepareDocuments(ctx);
  const ledger = ledgerFile(ctx, task);
  const linked = linkedDocs(ctx, task);
  const existing = ledgerLines(ctx, task);
  const have = (existing ?? []).map((l) => (l.includes("\t") ? (l.split("\t")[1] as string) : l));

  const norm: string[] = [];
  const problems: string[] = [];
  for (const g of given) {
    const rel = normalisePath(ctx, g, linked);
    const problem = o.revoke ? revokedPathProblem(rel, have) : knowledgePathProblem(ctx, rel, linked);
    if (problem !== undefined) {
      problems.push(problem);
      continue;
    }
    if (!norm.includes(rel)) norm.push(rel);
  }
  if (problems.length > 0) {
    out.err(problems.map((p) => `context acknowledge: ${p}\n`).join(""));
    throw die(`context acknowledge: ${problems.length} path(s) refused; nothing recorded. Give the paths as jig context guard prints them`);
  }

  const lines: string[] = [];
  for (const l of existing ?? []) {
    const { hash, rel, rest } = splitLedgerLine(l);
    if (rel === "" || norm.includes(rel)) continue;
    lines.push(rest !== "" ? `${hash}\t${rel}\t${rest}` : `${hash}\t${rel}`);
  }
  const stage = o.stage === "" ? "-" : o.stage;
  if (!o.revoke) {
    let hashed;
    try {
      hashed = await hashPaths(ctx, norm);
    } catch {
      throw die("context acknowledge: could not hash the documents");
    }
    for (const h of hashed) lines.push(`${h.hash}\t${h.path}\t${stage}`);
  }
  const body = sortBytes(lines).map((l) => `${l}\n`).join("");
  if (!writeViaTemp(ledger, body)) throw die(`context acknowledge: cannot write ${ledger}`);
  const n = norm.length;
  if (o.revoke) out.out(`revoked ${n} document(s) for ${task}\n`);
  else if (stage === "-") out.out(`acknowledged ${n} document(s) for ${task}\n`);
  else out.out(`acknowledged ${n} document(s) for ${task} at ${stage}\n`);
}

/**
 * `_ctx_tracked_rows`: every path whose reading is tracked, with why: the globals, the required set and the linked
 * documents that exist; one row per path, sorted. Workspace artifacts are never tracked.
 */
export function trackedRows(ctx: JigCtx, s: Selectors, required: readonly Row[]): Row[] {
  const rows: Row[] = [
    ...globalPaths(ctx).map((p) => ({ path: p, reason: "global" })),
    ...readRows(ctx, required),
    ...linkedDocs(ctx, s.task).map((p) => ({ path: p, reason: "linked" })),
  ];
  const seen = new Set<string>();
  const unique = rows.filter((r) => r.path !== "" && !seen.has(r.path) && seen.add(r.path));
  return unique.sort((a, b) => byteCompare(`${a.path}\t${a.reason}`, `${b.path}\t${b.reason}`));
}

/** `_ctx_pending_paths`: tracked documents with no acknowledgement, or whose content changed since one. */
export async function pendingPaths(ctx: JigCtx, s: Selectors, tracked: readonly Row[]): Promise<string[]> {
  if (tracked.length === 0) return [];
  const have = new Map<string, string>();
  for (const l of ledgerLines(ctx, s.task) ?? []) {
    const f = l.split("\t");
    if (f.length >= 2) have.set(f[1] as string, f[0] as string);
  }
  let hashed;
  try {
    hashed = await hashPaths(ctx, tracked.map((r) => r.path));
  } catch {
    throw die("context: could not hash the tracked documents");
  }
  return hashed.filter((h) => (have.get(h.path) ?? "") !== h.hash).map((h) => h.path);
}

/** `ctx_pending`: the tracked documents not acknowledged, one path per line. */
export async function pending(ctx: JigCtx, s: Selectors, out: Output): Promise<void> {
  const required = await requiredRows(ctx, s);
  if (s.task === "") {
    if (s.noTask) out.out("context pending: no task workspace; nothing tracked\n");
    return;
  }
  const paths = await pendingPaths(ctx, s, trackedRows(ctx, s, required));
  out.out(paths.map((p) => `${p}\n`).join(""));
}

/** `ctx_guard`: exit 0 when every tracked document is acknowledged; otherwise lists the pending ones and exits 1. */
export async function guard(ctx: JigCtx, s: Selectors, out: Output): Promise<number> {
  const required = await requiredRows(ctx, s);
  if (s.task === "") {
    out.out("context guard: no task workspace; nothing tracked\n");
    return 0;
  }
  const tracked = trackedRows(ctx, s, required);
  const pend = await pendingPaths(ctx, s, tracked);
  if (pend.length === 0) {
    out.out(`context guard: ok (${tracked.length} document(s) acknowledged)\n`);
    out.out(attributionText(ctx, s, tracked));
    return 0;
  }
  let err = `context guard: ${pend.length} of ${tracked.length} document(s) not acknowledged:\n`;
  const why = new Map(tracked.map((r) => [r.path, r.reason]));
  for (const p of pend) {
    const reason = why.get(p) ?? "";
    err += reason !== "" ? `  ${p}  (${reason})\n` : `  ${p}\n`;
  }
  err += `read them, then: jig context acknowledge --task ${s.task}${s.stage !== "" ? ` --stage ${s.stage}` : ""} --files <list>\n`;
  out.err(err);
  return 1;
}

/** `_ctx_guard_attribution`: whose acknowledgements a passing guard took: a line per stage they were made at,
 * and one saying so when none was made at the stage asked for. */
function attributionText(ctx: JigCtx, s: Selectors, tracked: readonly Row[]): string {
  const lines = ledgerLines(ctx, s.task);
  if (lines === undefined) return "";
  const stageOf = new Map<string, string>();
  for (const l of lines) {
    const f = l.split("\t");
    stageOf.set(f[1] ?? "", (f[2] ?? "") !== "" ? (f[2] as string) : "-");
  }
  const counts = new Map<string, number>();
  for (const r of tracked) {
    const st = stageOf.get(r.path) ?? "-";
    counts.set(st, (counts.get(st) ?? 0) + 1);
  }
  let text = "";
  let here = false;
  for (const line of sortBytes([...counts].map(([st, n]) => `${st}\t${n}`))) {
    const [st, n] = line.split("\t") as [string, string];
    if (st === "-") {
      text += `  ${n} acknowledged at no stage\n`;
    } else {
      text += `  ${n} acknowledged at ${st}\n`;
      if (st === s.stage) here = true;
    }
  }
  if (s.stage !== "" && !here) text += `  none acknowledged at ${s.stage}: this guard passed on acknowledgements made elsewhere\n`;
  return text;
}
