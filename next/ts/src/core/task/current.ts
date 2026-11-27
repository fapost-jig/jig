// Which task a checkout is working on: `task_current` and the base a task is judged against.

import type { JigCtx } from "../context.ts";
import { currentBranch } from "../git/read.ts";
import { cfg } from "../storage/config.ts";
import { parkedIds } from "../staging/parked.ts";
import { sortBytes } from "../storage/bytes.ts";
import { readStateValue } from "../storage/state-read.ts";
import { taskIdsWithState } from "../storage/tasks.ts";

/** `jig_task_base`: the `base_branch` a task recorded, else `git.base_branch` (main); an id that is not one gets the configured base. */
export function taskBase(ctx: JigCtx, id: string): string {
  const own = readStateValue(ctx, id, "base_branch");
  if (own !== undefined && own !== "") return own;
  return cfg(ctx, ctx.keys, "git.base_branch", "main");
}

/**
 * `_task_candidates_for_branch`: the ids, sorted, of every task whose `branch` is `branch`, whose status is
 * `active` or `ready`, and that is not paused. On the staging flow a `ready` task parked at the staging branch is not a
 * candidate either: it waits for a review or for "prepare for prod" and holds no current-task slot.
 */
export async function candidatesForBranch(ctx: JigCtx, branch: string): Promise<string[]> {
  let found: string[] = [];
  const ready: string[] = [];
  for (const id of taskIdsWithState(ctx)) {
    if (readStateValue(ctx, id, "branch") !== branch) continue;
    const status = readStateValue(ctx, id, "status");
    if (status !== "active" && status !== "ready") continue;
    if (readStateValue(ctx, id, "paused") === "true") continue;
    if (status === "ready") ready.push(id);
    found.push(id);
  }
  if (ready.length > 0 && cfg(ctx, ctx.keys, "git.flow", "direct") === "staging") {
    const parked = await parkedIds(ctx, ready);
    found = found.filter((id) => !parked.has(id));
  }
  return sortBytes(found);
}

export type CurrentTask =
  | { readonly kind: "one"; readonly id: string }
  | { readonly kind: "none" }
  | { readonly kind: "many"; readonly listing: string };

/**
 * `task_current`: exactly one candidate on the branch checked out here is the answer; none is a normal
 * outcome; several is refused with one line per candidate (what bash prints on stderr, exit 2).
 */
export async function currentTask(ctx: JigCtx): Promise<CurrentTask> {
  const branch = (await currentBranch(ctx)) ?? "detached";
  const candidates = await candidatesForBranch(ctx, branch);
  if (candidates.length === 0) return { kind: "none" };
  if (candidates.length === 1) return { kind: "one", id: candidates[0] as string };
  const listing = candidates
    .map((id) => `${id}  ${readStateValue(ctx, id, "status") ?? ""}  updated_at=${readStateValue(ctx, id, "updated_at") ?? ""}\n`)
    .join("");
  return { kind: "many", listing };
}
