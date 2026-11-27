// Finding the project root the way bash's jig_require_repo does, and the clone's revision from it.
//
// Imports only node:* and local modules that themselves import only node:* (see revision.ts): the
// command line reads the revision for its error envelope before anything else runs.

import fs from "node:fs";
import type { Ctx } from "../context.ts";
import { git, text } from "../exec.ts";
import { revisionRead } from "./revision.ts";

/**
 * The repository root of `cwd`, made physical (jig_repo_root, then `cd -P && pwd -P`);
 * undefined outside a repository or when git cannot answer.
 */
export async function projectRoot(ctx: Pick<Ctx, "exec">, cwd: string): Promise<string | undefined> {
  try {
    const r = await git(ctx, cwd, ["rev-parse", "--show-toplevel"]);
    if (r.code !== 0) return undefined;
    const top = text(r.stdout).replace(/\r?\n$/, "");
    return top === "" ? undefined : fs.realpathSync.native(top);
  } catch {
    return undefined;
  }
}

/**
 * The revision `json_run` reports: the clone's counter, read for the repository `cwd` is in;
 * 0 outside a repository (the envelope's "before Jig's first write in the clone").
 */
export async function revisionAt(ctx: Pick<Ctx, "exec">, cwd: string): Promise<number> {
  const root = await projectRoot(ctx, cwd);
  return root === undefined ? 0 : revisionRead(root);
}
