// The version `jig --version` prints, worked out as scripts/jig and scripts/lib/common.sh work it out.
//
// In a framework source checkout the version names unreleased code, `X.Y.Z+<short sha>`; at a
// release tag, and from a project's installed copy, it is the plain `X.Y.Z`
// (adr-20261106-copy-mode-projects-take-released-code-only). Git goes through the executor; the
// files are read by the storage layer.

import path from "node:path";
import type { Ctx } from "./context.ts";
import { git, text } from "./exec.ts";
import { JigError } from "./errors.ts";
import { declaredVersion, isSourceRoot, loadedVersion, realPath } from "./storage/framework.ts";

/** `jig_release_version`: `X.Y.Z` of tag `vX.Y.Z`, nothing for anything else. */
export function releaseVersion(tag: string): string | undefined {
  const m = /^v(\d+\.\d+\.\d+)$/.exec(tag);
  return m?.[1];
}

/** `_jig_source_git`: `dir` is the top of a git checkout of its own, not a folder inside somebody else's. */
async function isOwnCheckout(ctx: Ctx, dir: string): Promise<boolean> {
  const r = await git(ctx, dir, ["rev-parse", "--show-toplevel"]);
  if (r.code !== 0) return false;
  try {
    return realPath(text(r.stdout).replace(/\n$/, "")) === realPath(dir);
  } catch {
    return false;
  }
}

async function shortSha(ctx: Ctx, dir: string): Promise<string | undefined> {
  const r = await git(ctx, dir, ["rev-parse", "--short=7", "HEAD"]);
  const sha = text(r.stdout).replace(/\n$/, "");
  return r.code === 0 && sha !== "" ? sha : undefined;
}

/** `jig_source_release`: `v<declared>` points at HEAD. */
async function atReleaseTag(ctx: Ctx, dir: string, declared: string): Promise<boolean> {
  if (releaseVersion(`v${declared}`) === undefined) return false;
  if (!(await isOwnCheckout(ctx, dir))) return false;
  const r = await git(ctx, dir, ["tag", "--points-at", "HEAD"]);
  if (r.code !== 0) return false;
  return text(r.stdout).split("\n").includes(`v${declared}`);
}

/** `jig_source_version`: the declared `X.Y.Z` at its release tag, else `X.Y.Z+<sha>`, else `X.Y.Z+unknown`. */
export async function sourceVersion(ctx: Ctx, sourceRoot: string): Promise<string | undefined> {
  const declared = declaredVersion(path.join(sourceRoot, "scripts", "lib", "version.sh"));
  if (declared === undefined) return undefined;
  if (await atReleaseTag(ctx, sourceRoot, declared)) return declared;
  if (await isOwnCheckout(ctx, sourceRoot)) {
    const sha = await shortSha(ctx, sourceRoot);
    if (sha !== undefined) return `${declared}+${sha}`;
  }
  return `${declared}+unknown`;
}

/**
 * What `jig --version` prints after `jig `. `scriptsLib` is the framework's `scripts/lib` directory
 * this process runs from; the checkout (or project) it belongs to is two levels above its physical path.
 */
export async function jigVersion(ctx: Ctx, scriptsLib: string): Promise<string> {
  const fallback = loadedVersion(path.join(scriptsLib, "version.sh"));
  if (fallback === undefined) throw new JigError("failed", `cannot read JIG_VERSION from ${path.join(scriptsLib, "version.sh")}`);
  let root: string;
  try {
    root = path.resolve(realPath(scriptsLib), "..", "..");
  } catch {
    return fallback;
  }
  if (isSourceRoot(root)) {
    const v = await sourceVersion(ctx, root);
    if (v !== undefined && v !== "") return v;
  }
  return fallback;
}
