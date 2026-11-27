// The task workspaces under `.ai/workspace/tasks`: which ids there are, and the files inside them.

import fs from "node:fs";
import path from "node:path";
import type { Ctx } from "../context.ts";
import { sortBytes } from "./bytes.ts";
import { readText, writeViaTemp } from "./files.ts";
import { revisionBump } from "./revision.ts";
import { stateFile, taskDir, validTaskId } from "./state-read.ts";

export function tasksDir(ctx: Pick<Ctx, "root">): string {
  return path.join(ctx.root, ".ai", "workspace", "tasks");
}

/** `[ -f <tasks>/<id>/state ]`. The id must be valid: no path is built from one that is not. */
export function hasState(ctx: Pick<Ctx, "root">, id: string): boolean {
  if (!validTaskId(id)) return false;
  try {
    return fs.statSync(stateFile(ctx, id)).isFile();
  } catch {
    return false;
  }
}

/**
 * The directories of the tasks directory, as a shell glob over its subdirectories lists them (hidden names are not
 * matched, order is by bytes), that hold a `state` file and whose name is a valid task id.
 */
export function taskIdsWithState(ctx: Pick<Ctx, "root">): string[] {
  let names: string[];
  try {
    names = fs.readdirSync(tasksDir(ctx));
  } catch {
    return [];
  }
  return sortBytes(names.filter((n) => !n.startsWith(".") && validTaskId(n) && hasState(ctx, n)));
}

/** `[ -f <root>/<rel> ]` for a path inside a task's workspace directory (relative to the project root). */
export function workspaceFileExists(ctx: Pick<Ctx, "root">, rel: string): boolean {
  try {
    return fs.statSync(path.join(ctx.root, rel)).isFile();
  } catch {
    return false;
  }
}

/**
 * Append `text` to a file of a task's workspace through a temporary and a rename (the autopilot journal's
 * `_task_autopilot_log`), then raise the clone's revision. Throws when the file cannot be written.
 */
export function appendTaskFile(ctx: Pick<Ctx, "root" | "clock">, id: string, name: string, text: string): void {
  const file = path.join(taskDir(ctx, id), name);
  if (!writeViaTemp(file, (readText(file) ?? "") + text)) throw new Error(`cannot write ${file}`);
  revisionBump(ctx.root, ctx.clock);
}
