// What Jig reads from git for `context` and the checkout recorder. Every call goes through `ctx.exec`.

import type { Ctx } from "../context.ts";
import { git, text } from "../exec.ts";
import { sortBytes } from "../storage/bytes.ts";

type GitCtx = Pick<Ctx, "root" | "exec">;

const branchOf = new WeakMap<object, Promise<string | undefined>>();

/**
 * The branch checked out here, or undefined when HEAD is detached (`git symbolic-ref --short HEAD`). Asked of git once
 * per context: a call of Jig is one moment, and the recorder and the task lookup both ask.
 */
export function currentBranch(ctx: GitCtx): Promise<string | undefined> {
  let answer = branchOf.get(ctx);
  if (answer === undefined) {
    answer = askBranch(ctx);
    branchOf.set(ctx, answer);
  }
  return answer;
}

async function askBranch(ctx: GitCtx): Promise<string | undefined> {
  const r = await git(ctx, ctx.root, ["symbolic-ref", "--quiet", "--short", "HEAD"]);
  if (r.code !== 0) return undefined;
  const b = text(r.stdout).replace(/\n$/, "");
  return b === "" ? undefined : b;
}

/** `git worktree list --porcelain`, or nothing when git cannot say. */
export async function worktreeList(ctx: GitCtx): Promise<string> {
  const r = await git(ctx, ctx.root, ["worktree", "list", "--porcelain"]);
  return r.code === 0 ? text(r.stdout) : "";
}

async function verifies(ctx: GitCtx, ref: string): Promise<boolean> {
  const r = await git(ctx, ctx.root, ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
  return r.code === 0;
}

/** `jig_base_ref`: `refs/remotes/origin/<name>` when it exists, else `refs/heads/<name>`, else nothing. */
export async function baseRef(ctx: GitCtx, name: string): Promise<string> {
  if (name === "") return "";
  if (await verifies(ctx, `refs/remotes/origin/${name}`)) return `refs/remotes/origin/${name}`;
  if (await verifies(ctx, `refs/heads/${name}`)) return `refs/heads/${name}`;
  return "";
}

async function names(ctx: GitCtx, args: readonly string[]): Promise<string[]> {
  const r = await git(ctx, ctx.root, args);
  return r.code === 0 ? text(r.stdout).split("\n") : [];
}

/**
 * `jig_git_touched_files --base-branch <base>`: the diff against the merge base with the base branch,
 * the staged and unstaged diffs, and the untracked files, one path each, sorted by bytes.
 */
export async function touchedFiles(ctx: GitCtx, base: string): Promise<string[]> {
  const out: string[] = [];
  const ref = await baseRef(ctx, base);
  if (ref !== "") {
    const mb = await git(ctx, ctx.root, ["merge-base", ref, "HEAD"]);
    if (mb.code === 0) {
      const sha = text(mb.stdout).replace(/\n+$/, "");
      out.push(...(await names(ctx, ["diff", "--name-only", sha])));
    }
  }
  out.push(...(await names(ctx, ["diff", "--cached", "--name-only"])));
  out.push(...(await names(ctx, ["diff", "--name-only"])));
  out.push(...(await names(ctx, ["ls-files", "--others", "--exclude-standard"])));
  return sortBytes([...new Set(out.filter((l) => l !== ""))]);
}
