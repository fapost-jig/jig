// The reading half of a task's `state` file, which needs no schema: the id grammar and the validating builder of
// every path under a task's directory, and the line reader. Kept apart from state.ts so that the commands that only
// read (`context`) do not load the schema library (zod) at start-up.

import fs from "node:fs";
import path from "node:path";
import type { Ctx } from "../context.ts";
import { JigError } from "../errors.ts";
import { stateValue } from "./flat.ts";

/** `jig_valid_id`: the rule every path built from a task id follows. */
export function validTaskId(id: string): boolean {
  return id !== "" && !id.startsWith(".") && !id.startsWith("-") && !/[^A-Za-z0-9._-]/.test(id);
}

export function checkId(id: string): void {
  if (!validTaskId(id)) throw new JigError("usage", `invalid task id: ${id}`);
}

export function taskDir(ctx: Pick<Ctx, "root">, id: string): string {
  checkId(id);
  return path.join(ctx.root, ".ai", "workspace", "tasks", id);
}

export function stateFile(ctx: Pick<Ctx, "root">, id: string): string {
  return path.join(taskDir(ctx, id), "state");
}

export function readText(file: string): string | undefined {
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

