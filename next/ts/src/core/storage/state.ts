// A task's `state` file: `.ai/workspace/tasks/<id>/state`, flat `key: value` lines.
//
// Reading is bash's `jig_task_state_var`; writing is bash's `_task_state_set_into`, line for line,
// so a file written here is read by bash exactly as intended (the invariant test holds that).
// Only keys of schemas/state.md are written, only values bash reads back as written, and the file
// is replaced atomically (a temporary file in the same directory, then rename).

import fs from "node:fs";
import path from "node:path";
import { today } from "../clock.ts";
import type { Ctx } from "../context.ts";
import { JigError } from "../errors.ts";
import { TaskState, TASK_STATE_KEYS, isTaskStateKey } from "../../schemas/task-state.ts";
import type { TaskStateKey } from "../../schemas/task-state.ts";
import { lines, stateValue, trimStart } from "./flat.ts";
import { revisionBump } from "./revision.ts";
import type { RevisionRaise } from "./revision.ts";

/** `jig_valid_id`: the rule every path built from a task id follows. */
export function validTaskId(id: string): boolean {
  return id !== "" && !id.startsWith(".") && !id.startsWith("-") && !/[^A-Za-z0-9._-]/.test(id);
}

function checkId(id: string): void {
  if (!validTaskId(id)) throw new JigError("usage", `invalid task id: ${id}`);
}

export function taskDir(ctx: Pick<Ctx, "root">, id: string): string {
  checkId(id);
  return path.join(ctx.root, ".ai", "workspace", "tasks", id);
}

export function stateFile(ctx: Pick<Ctx, "root">, id: string): string {
  return path.join(taskDir(ctx, id), "state");
}

function readText(file: string): string | undefined {
  try {
    return fs.readFileSync(file, "utf8");
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT" || (e as NodeJS.ErrnoException).code === "ENOTDIR") return undefined;
    throw e;
  }
}

/** The raw text of a task's state, or undefined when the task has none. */
export function readStateText(ctx: Pick<Ctx, "root">, id: string): string | undefined {
  return readText(stateFile(ctx, id));
}

/** `jig_task_state_var`: one key; undefined when the key (or the task) has no line. */
export function readStateValue(ctx: Pick<Ctx, "root">, id: string, key: string): string | undefined {
  if (!validTaskId(id)) return undefined;
  const text = readText(path.join(ctx.root, ".ai", "workspace", "tasks", id, "state"));
  return text === undefined ? undefined : stateValue(text, key);
}

/**
 * Every known key of a task's state, validated; undefined when the task has no state file.
 * A key bash can read as a variable name (`[A-Za-z][A-Za-z0-9_]*`) counts once, its first line winning.
 */
export function readTaskState(ctx: Pick<Ctx, "root">, id: string): TaskState | undefined {
  const text = readStateText(ctx, id);
  if (text === undefined) return undefined;
  const seen: Record<string, string> = {};
  for (const line of lines(text)) {
    const colon = line.indexOf(":");
    if (colon < 0) continue;
    const key = line.slice(0, colon);
    if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(key) || key in seen) continue;
    seen[key] = trimStart(line.slice(colon + 1));
  }
  const known: Record<string, string> = {};
  for (const k of TASK_STATE_KEYS) {
    const v = seen[k];
    if (v !== undefined) known[k] = v;
  }
  const parsed = TaskState.safeParse(known);
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    throw new JigError("failed", `task ${id}: invalid state: ${issue?.path.join(".") ?? "?"}: ${issue?.message ?? "invalid"}`);
  }
  return parsed.data;
}

function checkEntry(key: string, value: string): asserts key is TaskStateKey {
  if (!isTaskStateKey(key)) throw new JigError("unknown-key", `state: ${key} is not a key of a task's state`);
  // A line break would split the value into a second key; a NUL cannot be in a bash variable;
  // and bash drops the blanks after the colon when it reads, so a value that starts with one
  // would come back different from what was written.
  if (/[\n\r\0]/.test(value)) throw new JigError("invalid-value", `state: ${key}: a value cannot contain a line break or NUL`);
  if (/^[ \t\v\f]/.test(value)) throw new JigError("invalid-value", `state: ${key}: a value cannot start with a blank`);
  const parsed = TaskState.shape[key].safeParse(value);
  if (!parsed.success) throw new JigError("invalid-value", `state: ${key}: invalid value: ${value}`);
}

/**
 * `_task_state_set_into`, the awk program of scripts/lib/task.sh:
 * every line of an existing key is rewritten in place; a key that is not there goes before the
 * first `created_at:` line, or last when there is none; `updated_at` is refreshed.
 */
export function setStateLine(text: string, key: string, value: string, day: string): string {
  const out: string[] = [];
  let done = false;
  for (const line of lines(text)) {
    if (line.startsWith(`${key}:`)) {
      out.push(`${key}: ${value}`);
      done = true;
    } else if (!done && line.startsWith("created_at:")) {
      out.push(`${key}: ${value}`);
      out.push(line);
      done = true;
    } else if (line.startsWith("updated_at:")) {
      out.push(`updated_at: ${day}`);
    } else {
      out.push(line);
    }
  }
  if (!done) out.push(`${key}: ${value}`);
  return out.map((l) => `${l}\n`).join("");
}

function writeAtomic(file: string, content: string): void {
  const tmp = `${file}.tmp.${process.pid}`;
  try {
    fs.writeFileSync(tmp, content, { flag: "w" });
    fs.renameSync(tmp, file);
  } catch (e) {
    fs.rmSync(tmp, { force: true });
    throw e;
  }
}

/**
 * What a state write answers. The write has landed whatever this says: `revisionRaised: false` (with
 * bash's warning) means only that the clone's revision could not be raised, so a `--json` reader may
 * miss the change. Like bash's `_task_rewrite_state`, which calls jig_record_changed after the write,
 * a failed raise is a warning and never a failed write. bash's jig_task_state_forget (an in-process
 * cache of the state read) has no counterpart here, and neither has the status-page redraw of
 * jig_record_changed: neither skeleton has a status page (go-skeleton did the same).
 */
export interface StateWrite {
  readonly revisionRaised: boolean;
  readonly warning?: string;
}

function written(r: RevisionRaise): StateWrite {
  return r.warning === undefined ? { revisionRaised: r.raised } : { revisionRaised: r.raised, warning: r.warning };
}

/**
 * Set keys of an existing task's state, in order, as one write. Each key is written as bash's
 * `jig task set` would write it alone (so `updated_at` is refreshed to today's local date).
 * The clone's revision is raised right after the write lands.
 */
export function writeTaskState(ctx: Pick<Ctx, "root" | "clock">, id: string, updates: Partial<Record<TaskStateKey, string>>): StateWrite {
  const file = stateFile(ctx, id);
  const entries = Object.entries(updates).filter((e): e is [string, string] => e[1] !== undefined);
  for (const [k, v] of entries) checkEntry(k, v);
  let text = readText(file);
  if (text === undefined) throw new JigError("not-found", `state: unknown task: ${id}`);
  const day = today(ctx.clock);
  for (const [k, v] of entries) text = setStateLine(text, k, v, day);
  writeAtomic(file, text);
  return written(revisionBump(ctx.root, ctx.clock));
}

/**
 * File a task's state from scratch, keys in the given order. Refuses to replace an existing one.
 * The clone's revision is raised right after the write lands.
 */
export function createTaskState(ctx: Pick<Ctx, "root" | "clock">, id: string, entries: ReadonlyArray<readonly [TaskStateKey, string]>): StateWrite {
  const dir = taskDir(ctx, id);
  const file = path.join(dir, "state");
  for (const [k, v] of entries) checkEntry(k, v);
  if (readText(file) !== undefined) throw new JigError("already-exists", `state: task already exists: ${id}`);
  fs.mkdirSync(dir, { recursive: true });
  writeAtomic(file, entries.map(([k, v]) => `${k}: ${v}\n`).join(""));
  return written(revisionBump(ctx.root, ctx.clock));
}
