// Content hashes of files, as `jig_hash_list` and the ledger's `_ctx_hash_paths` take them: one
// `git hash-object --no-filters --stdin-paths` per directory, in the project's own hash space.

import type { Ctx } from "../context.ts";
import { die } from "../errors.ts";
import { git, text } from "../exec.ts";
import { sortBytes } from "../storage/bytes.ts";

type GitCtx = Pick<Ctx, "root" | "exec">;

/** `jig_hash_git_dir`: the project's absolute git directory, or undefined when git cannot say. */
async function gitDirOf(ctx: GitCtx): Promise<string | undefined> {
  const r = await git(ctx, ctx.root, ["rev-parse", "--absolute-git-dir"]);
  if (r.code !== 0) return undefined;
  const d = text(r.stdout).replace(/\n+$/, "");
  return d === "" ? undefined : d;
}

/**
 * `jig_hash_list <base> <file>`: the blob hash of every path, in order, from one git process run in `base`.
 * The paths are relative to `base`. Nothing for an empty list; throws when git refuses the batch.
 */
export async function hashList(ctx: GitCtx, base: string, paths: readonly string[]): Promise<string[]> {
  if (paths.length === 0) return [];
  const gitDir = await gitDirOf(ctx);
  const r = await git(ctx, base, ["hash-object", "--no-filters", "--stdin-paths"], {
    input: `${paths.join("\n")}\n`,
    ...(gitDir === undefined ? {} : { env: { GIT_DIR: gitDir } }),
  });
  if (r.code !== 0) throw die(`cannot hash ${paths.length} file(s) in ${base}`);
  return text(r.stdout).split("\n").filter((l) => l !== "");
}

export interface HashedPath {
  readonly hash: string;
  readonly path: string;
}

/**
 * `_ctx_hash_paths`: `{hash, path}` for every path. Repository-relative paths are hashed by one process from the
 * project root; absolute ones (documents a `Linked:` line reaches) by one process per directory, on bare file names.
 */
export async function hashPaths(ctx: GitCtx, paths: readonly string[]): Promise<HashedPath[]> {
  const rel = paths.filter((p) => p !== "" && !p.startsWith("/"));
  const abs = paths.filter((p) => p.startsWith("/"));
  const out: HashedPath[] = [];
  if (rel.length > 0) {
    const hashes = await hashList(ctx, ctx.root, rel);
    rel.forEach((p, i) => out.push({ hash: hashes[i] ?? "", path: p }));
  }
  const dirs = sortBytes([...new Set(abs.map((p) => p.replace(/\/[^/]*$/, "")))]).filter((d) => d !== "");
  for (const dir of dirs) {
    const names = abs.filter((p) => p.startsWith(`${dir}/`) && !p.slice(dir.length + 1).includes("/")).map((p) => p.slice(dir.length + 1));
    const hashes = await hashList(ctx, dir, names);
    names.forEach((n, i) => out.push({ hash: hashes[i] ?? "", path: `${dir}/${n}` }));
  }
  return out;
}
