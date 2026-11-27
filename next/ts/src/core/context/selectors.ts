// The selectors `resolve`, `pending` and `guard` share (`_ctx_parse_selectors`): the task, the stage, the files,
// the domains, the topics and the ids a call names, with what the task and the checkout supply for what it leaves out.

import type { JigCtx, Output } from "../context.ts";
import { die } from "../errors.ts";
import { touchedFiles } from "../git/read.ts";
import { GLOBAL_DOCS } from "../storage/knowledge.ts";
import { isReadableFile } from "../storage/files.ts";
import { readStateValue, validTaskId } from "../storage/state-read.ts";
import { hasState } from "../storage/tasks.ts";
import { currentTask, taskBase } from "../task/current.ts";

/** What the words of a call say, before the project is asked anything. */
export interface RawSelectors {
  readonly task: string;
  readonly noTask: boolean;
  readonly stage: string;
  readonly filesArg: string;
  readonly filesStdin: boolean;
  readonly domainsArg: string;
  /** `--topics`, commas as spaces. */
  readonly topics: string;
  /** `--ids`, commas as spaces. */
  readonly ids: string;
  readonly catalog: boolean;
  readonly all: boolean;
}

/** The selectors of a call: the CTX_* variables of the bash library. */
export interface Selectors {
  readonly task: string;
  /** Whether the task was named with `--task` (one guessed from the branch is not a declared entry into a stage). */
  readonly taskNamed: boolean;
  /** Whether `--no-task` was given. */
  readonly noTask: boolean;
  readonly stage: string;
  /** Newline-separated; empty for none. */
  readonly files: string;
  /** Space-separated (commas read as spaces); empty for none. */
  readonly domains: string;
  readonly topics: string;
  readonly ids: string;
  readonly catalog: boolean;
  readonly all: boolean;
}

/** `jig_valid_stage`. */
export function validStage(stage: string): boolean {
  return [
    "analyze",
    "discover",
    "specify",
    "alternatives",
    "design",
    "plan",
    "implement",
    "review",
    "architecture-review",
    "verify",
    "consolidate",
  ].includes(stage);
}

/** `_ctx_check_globals`: the three global documents must be there and readable. */
export function checkGlobals(ctx: JigCtx): void {
  for (const g of GLOBAL_DOCS) {
    if (!isReadableFile(`${ctx.root}/.ai/knowledge/${g}`)) {
      throw die(`context: missing or unreadable mandatory global: .ai/knowledge/${g}; restore project knowledge`);
    }
  }
}

/** `_ctx_parse_selectors`, after the words are read: the checks, the task, the files and the domains. */
export async function resolveSelectors(ctx: JigCtx, raw: RawSelectors, stdin: () => Promise<string>, out: Output): Promise<Selectors> {
  if (raw.noTask && raw.task !== "") throw die("context: --task conflicts with --no-task");
  checkGlobals(ctx);
  let task = raw.task;
  if (task !== "") {
    if (!validTaskId(task)) throw die(`invalid task id: ${task}`);
    if (!hasState(ctx, task)) throw die(`context: unknown task: ${task}`);
  } else if (!raw.noTask) {
    const current = await currentTask(ctx);
    if (current.kind === "one") task = current.id;
    else if (current.kind === "many") out.err(current.listing);
  }
  let files: string;
  if (raw.filesStdin) files = (await stdin()).replace(/\n+$/, "");
  else if (raw.filesArg !== "") files = raw.filesArg.replaceAll(",", "\n").replace(/\n+$/, "");
  else files = (await touchedFiles(ctx, taskBase(ctx, task))).join("\n");
  let domains = "";
  if (raw.domainsArg !== "") domains = raw.domainsArg.replaceAll(",", " ");
  else if (task !== "") domains = (readStateValue(ctx, task, "domains") ?? "").replaceAll(",", " ");
  return {
    task,
    taskNamed: raw.task !== "",
    noTask: raw.noTask,
    stage: raw.stage,
    files,
    domains,
    topics: raw.topics,
    ids: raw.ids,
    catalog: raw.catalog,
    all: raw.all,
  };
}
