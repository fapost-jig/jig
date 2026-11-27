// The check every writer of a task's workspace passes before it writes: `_task_guard_write`
// (`_task_workspace_root`). A link anywhere on the way is judged by where it leads, never by its shape.

import path from "node:path";
import type { Ctx } from "../context.ts";
import { JigError, die } from "../errors.ts";
import { worktreeList } from "../git/read.ts";
import { isFile, isSymlink, physicalDir } from "../storage/files.ts";
import { taskDir } from "../storage/state-read.ts";
import { tasksDir } from "../storage/tasks.ts";

type GuardCtx = Pick<Ctx, "root" | "exec">;

/** `_task_worktree_holds`: whether `want` is `<W>/<relative>` for this checkout or for a worktree git lists. */
export async function worktreeHolds(ctx: GuardCtx, want: string, rel: string): Promise<boolean> {
  const here = physicalDir(ctx.root);
  if (here === undefined) return false;
  if (want === `${here}/${rel}`) return true;
  for (const line of (await worktreeList(ctx)).split("\n")) {
    if (!line.startsWith("worktree ")) continue;
    const p = physicalDir(line.slice("worktree ".length));
    if (p !== undefined && want === `${p}/${rel}`) return true;
  }
  return false;
}

/** `_task_workspace_root`: the physical workspace of task `id`; throws (as bash dies) naming `cmd` when it is not this repository's own. */
export async function workspaceRoot(ctx: GuardCtx, id: string, cmd: string): Promise<string> {
  const root = taskDir(ctx, id);
  if (!isFile(path.join(root, "state"))) throw new JigError("not-found", `${cmd}: unknown task: ${id}`);
  const tasksRoot = physicalDir(tasksDir(ctx));
  if (tasksRoot === undefined) throw die(`${cmd}: cannot inspect .ai/workspace/tasks`);
  if (!(await worktreeHolds(ctx, tasksRoot, ".ai/workspace/tasks"))) {
    throw die(`${cmd}: .ai/workspace/tasks leads to ${tasksRoot}, which is no checkout of this repository`);
  }
  if (isSymlink(root)) {
    const real = physicalDir(root);
    if (real === undefined || !(await worktreeHolds(ctx, real, `.ai/workspace/tasks/${id}`))) {
      throw die(`${cmd}: linked task workspace is unsupported unless it is this task's workspace in another worktree`);
    }
    return real;
  }
  const real = physicalDir(root);
  if (real === undefined) throw die(`${cmd}: cannot inspect workspace`);
  if (real !== `${tasksRoot}/${id}`) throw die(`${cmd}: workspace outside task root`);
  return real;
}

/** `_task_guard_write` asked in a subshell: whether the check passes. */
export async function workspaceGuardPasses(ctx: GuardCtx, id: string, cmd: string): Promise<boolean> {
  try {
    await workspaceRoot(ctx, id, cmd);
    return true;
  } catch {
    return false;
  }
}
