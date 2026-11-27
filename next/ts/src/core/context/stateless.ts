// `jig context` without a subcommand: the knowledge that matches a change (ctx_stateless in
// scripts/lib/context.sh; ADR-0014). Deterministic: the files and domains it is given, or the ones
// the checkout and the task supply.

import type { JigCtx, Output } from "../context.ts";
import { die } from "../errors.ts";
import { touchedFiles } from "../git/read.ts";
import { matchedDocs } from "../knowledge/docs.ts";
import { pauseRequest, queuePlace, utcAgo } from "../queue/read.ts";
import { byteCompare } from "../storage/bytes.ts";
import { GLOBAL_DOCS, isFileAt, prepareDocuments } from "../storage/knowledge.ts";
import { readQueueLines } from "../storage/queue.ts";
import { readStateValue, validTaskId } from "../storage/state-read.ts";
import { hasState } from "../storage/tasks.ts";
import { currentTask, taskBase } from "../task/current.ts";

/** Workspace artifacts other than task.md, in the order they are reported. */
export const WORKSPACE_ARTIFACTS = ["discovery.md", "spec.md", "alternatives.md", "design.md", "plan.md", "review.md", "verification.md", "handoff.md"];

export type Format = "list" | "paths";

export interface StatelessOptions {
  readonly task: string;
  readonly noTask: boolean;
  /** `--files <list>`; empty when not given. */
  readonly filesArg: string;
  readonly filesStdin: boolean;
  readonly domainsArg: string;
  readonly all: boolean;
  readonly format: Format;
}

interface Row {
  readonly label: string;
  readonly path: string;
  readonly reason: string;
}

/** `%-10s`. */
export function pad10(s: string): string {
  return s.length >= 10 ? s : s + " ".repeat(10 - s.length);
}

/** What `$(...)` leaves of a text: its trailing newlines removed. */
function chompNewlines(s: string): string {
  return s.replace(/\n+$/, "");
}

/** The task this call is about: `--task` (which must exist), else the current one; none under `--no-task`. */
async function resolveTask(ctx: JigCtx, o: StatelessOptions, out: Output): Promise<string> {
  if (o.noTask && o.task !== "") throw die("context: --task conflicts with --no-task");
  if (o.task !== "") {
    if (!validTaskId(o.task)) throw die(`invalid task id: ${o.task}`);
    if (!hasState(ctx, o.task)) throw die(`context: unknown task: ${o.task}`);
    return o.task;
  }
  if (o.noTask) return "";
  const current = await currentTask(ctx);
  if (current.kind === "one") return current.id;
  // Several candidates: the workspace is left out, and the caller is told why.
  if (current.kind === "many") out.err(current.listing);
  return "";
}

/** `_ctx_queue_lines`: the task's place in the queue, and a pause asked of it that it has not honoured. */
export function queueLines(ctx: JigCtx, id: string): string {
  const queue = readQueueLines(ctx);
  let text = "";
  const place = queuePlace(queue, id);
  if (place !== undefined) {
    const level = place.level === "-" ? "the top level" : place.level;
    const prio = place.priority === "-" ? "no priority" : `priority ${place.priority}`;
    text += `${pad10("queue:")} ${place.rank} of ${place.count} on ${level}, ${prio}\n`;
    for (const d of place.deps) if (d.on !== "") text += `${pad10("queue:")} waits for ${d.on}: ${d.reason}\n`;
  }
  const pause = pauseRequest(queue, id);
  if (pause !== undefined) {
    const ago = utcAgo(ctx.clock, pause.at);
    const when = ago === "" ? `at ${pause.at}` : ago === "just now" ? ago : `${ago} ago`;
    const why = pause.reason === "" ? "" : ` (${pause.reason})`;
    text += `${pad10("queue:")} pause requested ${when}${why}; honoured when the next stage of the task resolves its context\n`;
  }
  return text;
}

export async function statelessContext(ctx: JigCtx, o: StatelessOptions, stdin: () => Promise<string>, out: Output): Promise<void> {
  const taskId = await resolveTask(ctx, o, out);

  // files
  let files: string;
  if (o.filesStdin) files = chompNewlines(await stdin());
  else if (o.filesArg !== "") files = chompNewlines(o.filesArg.replaceAll(",", "\n"));
  else files = (await touchedFiles(ctx, taskBase(ctx, taskId))).join("\n");
  const fileList = files.split("\n");

  // domains
  let domains = "";
  if (o.domainsArg !== "") domains = o.domainsArg;
  else if (taskId !== "") domains = readStateValue(ctx, taskId, "domains") ?? "";

  // rows
  await prepareDocuments(ctx);
  const rows: Row[] = [];
  for (const g of GLOBAL_DOCS) {
    if (isFileAt(ctx, `.ai/knowledge/${g}`)) rows.push({ label: "global", path: `.ai/knowledge/${g}`, reason: "" });
  }
  const matched = matchedDocs(ctx, fileList, files !== "", domains, o.all)
    .map((m) => ({ line: `${m.path}\t${m.reason}`, m }))
    .sort((a, b) => byteCompare(a.line, b.line));
  for (const { m } of matched) rows.push({ label: "matched", path: m.path, reason: m.reason });
  if (taskId !== "") {
    const wdir = `.ai/workspace/tasks/${taskId}`;
    if (isFileAt(ctx, `${wdir}/task.md`)) rows.push({ label: "workspace", path: `${wdir}/task.md`, reason: "" });
    for (const w of WORKSPACE_ARTIFACTS) {
      if (isFileAt(ctx, `${wdir}/${w}`)) rows.push({ label: "workspace", path: `${wdir}/${w}`, reason: "" });
    }
  }

  // render
  if (rows.length === 0) return;
  if (o.format === "paths") {
    out.out(rows.map((r) => `${r.path}\n`).join(""));
    return;
  }
  for (const r of rows) {
    out.out(r.reason === "" ? `${pad10(`${r.label}:`)} ${r.path}\n` : `${pad10(`${r.label}:`)} ${r.path}  (${r.reason})\n`);
  }
  if (taskId !== "") out.out(queueLines(ctx, taskId));
}

