// `jig context resolve`: what must be read before the files are changed (ctx_resolve in scripts/lib/context.sh).
// Prints the global documents, the required ones (a stub through its source), with `--catalog` the ones on offer,
// the task's workspace, its linked documents and its place in the queue. A named task entering a named stage
// honours a pause asked of it first, and exits 4.

import { nowUtc, today } from "../clock.ts";
import type { JigCtx, Output } from "../context.ts";
import { list, readPath, scalar } from "../knowledge/docs.ts";
import { cancelPauseRequest } from "../queue/write.ts";
import { pauseRequest } from "../queue/read.ts";
import { byteCompare } from "../storage/bytes.ts";
import { GLOBAL_DOCS, documentFrontmatter, isFileAt } from "../storage/knowledge.ts";
import { readQueueLines } from "../storage/queue.ts";
import { revisionRead } from "../storage/revision.ts";
import { readStateValue } from "../storage/state-read.ts";
import { appendTaskFile, hasState } from "../storage/tasks.ts";
import { workspaceRoot } from "../task/workspace.ts";
import { linkedLines } from "./linked.ts";
import { activeDocs, requiredRows, words } from "./required.ts";
import type { Row } from "./required.ts";
import type { Selectors } from "./selectors.ts";
import { WORKSPACE_ARTIFACTS, pad10, queueLines } from "./stateless.ts";

/** `_ctx_global_rows`: the global documents that are present. */
export function globalPaths(ctx: JigCtx): string[] {
  return GLOBAL_DOCS.filter((g) => isFileAt(ctx, `.ai/knowledge/${g}`)).map((g) => `.ai/knowledge/${g}`);
}

/** `_ctx_workspace_rows`: the current task's own artifacts. */
export function workspacePaths(ctx: JigCtx, task: string): string[] {
  if (task === "") return [];
  const wdir = `.ai/workspace/tasks/${task}`;
  const out: string[] = [];
  if (isFileAt(ctx, `${wdir}/task.md`)) out.push(`${wdir}/task.md`);
  for (const w of WORKSPACE_ARTIFACTS) if (isFileAt(ctx, `${wdir}/${w}`)) out.push(`${wdir}/${w}`);
  return out;
}

/**
 * `_ctx_read_rows`: the required rows as the agent reads them: a stub's row names its source, and its reason
 * says which stub linked it.
 */
export function readRows(ctx: JigCtx, rows: readonly Row[]): Row[] {
  return rows.map((r) => {
    const fm = documentFrontmatter(ctx, r.path);
    const source = fm === undefined ? "" : scalar(fm.data, "source");
    if (source === "") return r;
    let shown = source;
    try {
      shown = readPath(ctx, r.path, source);
    } catch {
      // the path stays the source's, as bash prints it
    }
    return { path: shown, reason: `${r.reason}; linked by ${fm === undefined ? "" : scalar(fm.data, "id")}` };
  });
}

/**
 * `_ctx_catalog_rows`: id and summary of every active document that is not required and either belongs to an
 * entered domain or is project-wide (neither `domains` nor `paths`); metadata only. Sorted.
 */
function catalogRows(ctx: JigCtx, s: Selectors, required: readonly Row[]): string[] {
  const domains = words(s.domains);
  const out: string[] = [];
  for (const d of activeDocs(ctx, s.all)) {
    if (required.some((r) => r.path === d.path)) continue;
    if (scalar(d.data, "load") === "stage") continue;
    const docDomains = list(d.data, "domains");
    let hit = false;
    if (docDomains.length === 0) hit = list(d.data, "paths").length === 0;
    else if (s.domains !== "") hit = docDomains.some((x) => domains.includes(x));
    if (!hit) continue;
    let shown = d.path;
    let summary = scalar(d.data, "summary");
    if (summary === "") summary = "(no summary)";
    const source = scalar(d.data, "source");
    if (source !== "") {
      try {
        shown = readPath(ctx, d.path, source);
      } catch {
        summary = `missing source: ${source}`;
      }
    }
    out.push(`${shown}\t${scalar(d.data, "id")}\t${summary}`);
  }
  return out.sort(byteCompare);
}

/** `IFS=<tab> read -r a b c`: runs of tabs separate, so an empty middle field is skipped; the rest goes to the last name. */
function readTabbed(line: string): [string, string, string] {
  let rest = line.replace(/^\t+/, "");
  const take = (): string => {
    const i = rest.indexOf("\t");
    if (i < 0) {
      const all = rest;
      rest = "";
      return all;
    }
    const field = rest.slice(0, i);
    rest = rest.slice(i).replace(/^\t+/, "");
    return field;
  };
  const a = take();
  const b = take();
  return [a, b, rest.replace(/\t+$/, "")];
}

/**
 * `_ctx_honour_pause`: a named task entering a named stage honours a pause asked of it, before any context is
 * printed (adr-20261019-a-pause-request-is-honoured-at-the-stage-boundary). What `jig task pause <id> --if-requested
 * --stage <s>` does, in this process: the request leaves the queue (read again and retried up to three times when
 * another write lands in between), the task's `paused` fields are set, an autopilot run that is on journals it, and the
 * `paused:` and `next:` lines are printed. A pause that cannot be made is a warning naming why, and the context follows.
 */
async function honourPause(ctx: JigCtx, id: string, stage: string, out: Output): Promise<boolean> {
  if (pauseRequest(readQueueLines(ctx), id) === undefined) return false;
  const warn = (why: string): void => out.err(`jig: warning: context: the pause requested for ${id} was not honoured: ${why}\n`);
  try {
    await workspaceRoot(ctx, id, "task pause");
  } catch (e) {
    warn(`jig: error: ${e instanceof Error ? e.message : String(e)}`);
    return false;
  }
  if (!hasState(ctx, id) || readStateValue(ctx, id, "paused") === "true") return false;

  // `_task_pause_take_request`
  const said: string[] = [];
  let request: { at: string; reason: string } | undefined;
  for (let tries = 0; request === undefined; ) {
    const asked = pauseRequest(readQueueLines(ctx), id);
    if (asked === undefined) return false;
    // the revision is read before the queue, as `jig queue` reads it
    const r = cancelPauseRequest(ctx, id, revisionRead(ctx.root));
    if (r.kind === "taken") {
      request = r;
    } else if (r.kind === "none") {
      return false;
    } else if (r.kind === "failed") {
      // A cancel that failed may still have landed: a request that is gone counts as taken out.
      if (pauseRequest(readQueueLines(ctx), id) !== undefined) {
        warn(`jig: error: task pause: cannot take the pause request of ${id} out of the queue: exit 1: ${r.why}`);
        return false;
      }
      said.push(`jig: warning: task pause: the pause request of ${id} left the queue, but jig queue cancel failed: exit 1: ${r.why}`);
      request = asked;
    } else if (++tries >= 3) {
      warn(`jig: error: task pause: the queue kept changing; the pause request of ${id} stays`);
      return false;
    }
  }

  const why = request.reason === "" ? `pause requested at ${request.at}` : `pause requested at ${request.at}: ${request.reason}`;
  try {
    const { writeTaskState } = await import("../storage/state.ts");
    writeTaskState(ctx, id, { paused: "true" });
    writeTaskState(ctx, id, { paused_at: today(ctx.clock) });
    writeTaskState(ctx, id, { paused_reason: why });
    // `_task_autopilot_log`: a run that is on writes a `pause` line in its journal.
    if (readStateValue(ctx, id, "autopilot") === "on") {
      appendTaskFile(ctx, id, "autopilot", `${nowUtc(ctx.clock)}\tpause\t${stage} not entered: ${why}\n`);
    }
  } catch (e) {
    warn([...said, `jig: error: ${e instanceof Error ? e.message : String(e)}`].join("\n"));
    return false;
  }
  out.out(`${said.map((l) => `${l}\n`).join("")}paused: ${id} (${why}); stage ${stage} not entered\n`);
  out.out(`next:      a person asked for this pause; do not start the ${stage} stage, end the session; jig task resume ${id} continues the task\n`);
  return true;
}

/** `ctx_resolve`, after the selectors are read. Returns the exit status: 4 when the task was paused. */
export async function resolveContext(ctx: JigCtx, s: Selectors, out: Output): Promise<number> {
  if (s.taskNamed && s.stage !== "" && (await honourPause(ctx, s.task, s.stage, out))) return 4;

  const required = await requiredRows(ctx, s);
  let text = "";
  for (const g of globalPaths(ctx)) text += `${pad10("global:")} ${g}\n`;
  for (const r of readRows(ctx, required)) text += `${pad10("required:")} ${r.path}  (${r.reason})\n`;
  if (s.catalog) {
    for (const line of catalogRows(ctx, s, required)) {
      const [p, id, summary] = readTabbed(line);
      text += `${pad10("catalog:")} ${p}  [${id}] ${summary}\n`;
    }
  }
  for (const w of workspacePaths(ctx, s.task)) text += `${pad10("workspace:")} ${w}\n`;
  text += await linkedLines(ctx, s.task);
  if (s.task !== "") text += queueLines(ctx, s.task);
  out.out(text);
  return 0;
}

