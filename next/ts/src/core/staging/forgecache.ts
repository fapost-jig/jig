// The forge cache, `<project>/.ai/runtime/forge-cache`: what the last `jig housekeeping` read from the forge about pull
// requests, one tab-separated line each, newest first (`<head> <base> <state> <ci> <fetched_at> <commit> <url> ...`).
// Read here exactly as 0.51.2 reads it (`forgecache_read`): comment and empty lines left out, nothing when there is no file.
// Never fetched from here: no forge is asked.

import path from "node:path";
import type { Ctx } from "../context.ts";
import { isSymlink, physicalDir, readDataLines } from "../storage/files.ts";
import { worktreeHolds } from "../task/workspace.ts";

/**
 * `forgecache_file`: where the cache is. A checkout that borrows the whole tasks directory of another worktree of this
 * repository (`_task_borrowed_tasks_root`) reads that worktree's cache.
 */
export async function forgeCacheFile(ctx: Pick<Ctx, "root" | "exec">): Promise<string> {
  const link = path.join(ctx.root, ".ai", "workspace", "tasks");
  if (isSymlink(link)) {
    const real = physicalDir(link);
    if (real !== undefined && (await worktreeHolds(ctx, real, ".ai/workspace/tasks"))) {
      return `${real.slice(0, -"/workspace/tasks".length)}/runtime/forge-cache`;
    }
  }
  return path.join(ctx.root, ".ai", "runtime", "forge-cache");
}

/** `forgecache_read`. */
export async function readForgeCache(ctx: Pick<Ctx, "root" | "exec">): Promise<string[]> {
  return readDataLines(await forgeCacheFile(ctx));
}
