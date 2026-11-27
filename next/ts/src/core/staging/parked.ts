// Which tasks wait at the staging branch (adr-20261112-a-task-waiting-at-staging-is-parked-and-resuming-it-is-its-status),
// as far as the current-task lookup needs: a parked `ready` task is no candidate. Ported from scripts/lib/task.sh
// (`_task_parked_read`), common.sh (`jig_parked_states`, `jig_staging_states`, `_jig_staging_walk`) and config.sh
// (`jig_staging_in_use`, `jig_git_flow_problems`). Derived on every call from git and the forge cache, written nowhere.
// Not ported, because the lookup never asks: the reason a task is parked (review or signal), the landing hint and the
// review columns, and the walk's `own`, `carry` and `reach` lines.

import type { JigCtx } from "../context.ts";
import { git, text } from "../exec.ts";
import { cfg } from "../storage/config.ts";
import { readStateValue } from "../storage/state-read.ts";
import { taskBase } from "../task/current.ts";
import { readForgeCache } from "./forgecache.ts";

/** `jig_staging_in_use`: the staging branch's name when the flow is `staging` and nothing in its settings is wrong; else undefined. */
export async function stagingInUse(ctx: JigCtx): Promise<string | undefined> {
  if (cfg(ctx, ctx.keys, "git.flow", "direct") !== "staging") return undefined;
  // jig_git_flow_problems: any fault means the staging flow is not in use
  const branch = cfg(ctx, ctx.keys, "git.staging_branch", "");
  if (branch === "") return undefined;
  if ((await git(ctx, ctx.root, ["check-ref-format", "--branch", branch])).code !== 0) return undefined;
  if (branch.startsWith("refs/") || branch.startsWith("origin/")) return undefined;
  if (branch === cfg(ctx, ctx.keys, "git.base_branch", "main")) return undefined;
  if (!["pr", "external"].includes(cfg(ctx, ctx.keys, "git.staging_land", "pr"))) return undefined;
  if (!["ask", "require", "none"].includes(cfg(ctx, ctx.keys, "git.staging_review", "ask"))) return undefined;
  if (!["human", "auto"].includes(cfg(ctx, ctx.keys, "git.promote_merge", "human"))) return undefined;
  return branch;
}

interface Row {
  readonly id: string;
  readonly branch: string;
  readonly base: string;
}

async function refSha(ctx: JigCtx, args: readonly string[]): Promise<string[]> {
  const r = await git(ctx, ctx.root, args);
  return r.code === 0 ? text(r.stdout).split("\n").filter((l) => l !== "") : [];
}

/**
 * `jig_staging_states`, with `_jig_staging_walk`'s `state` lines: the ids of the rows whose own work reached origin's
 * staging branch, with `on` (every own commit not on staging is a merge of the base) or `behind`.
 * A task's own commits are those its branch reaches and its base does not; a merge whose every parent but the first is in
 * the base or on staging brings those in and is not the task's own work.
 */
async function stagingStates(ctx: JigCtx, staging: string, rows: readonly Row[]): Promise<Map<string, "on" | "behind">> {
  const out = new Map<string, "on" | "behind">();
  if (rows.length === 0) return out;
  const stipLines = await refSha(ctx, ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${staging}^{commit}`]);
  const stip = stipLines[0];
  if (stip === undefined || stip === "") return out;

  // each row's tip and base from one listing of the refs
  const refs = new Map<string, string>();
  for (const l of await refSha(ctx, ["for-each-ref", "--format=%(refname)\t%(objectname)", "refs/heads", "refs/remotes/origin"])) {
    const [name, sha] = l.split("\t");
    if (name !== undefined && sha !== undefined) refs.set(name, sha);
  }
  const tipOf = (n: string): string => refs.get(`refs/heads/${n}`) ?? refs.get(`refs/remotes/origin/${n}`) ?? "";
  const baseOf = (n: string): string => refs.get(`refs/remotes/origin/${n}`) ?? refs.get(`refs/heads/${n}`) ?? "";
  const tasks: { id: string; tip: string; base: string; baseSha: string }[] = [];
  for (const r of rows) {
    if (r.id === "" || r.branch === "" || r.base === "") continue;
    const tip = tipOf(r.branch);
    const baseSha = baseOf(r.base);
    if (tip !== "" && baseSha !== "") tasks.push({ id: r.id, tip, base: r.base, baseSha });
  }
  const bases = [...new Map(tasks.map((t) => [`${t.base}:${t.baseSha}`, t] as const)).values()];

  // per base: the commits the tips reach and the base does not (with parents), and staging's commits the base lacks
  const own = new Set<string>();
  const parents = new Map<string, string[]>();
  const on = new Set<string>();
  for (const b of bases) {
    const tips = tasks.filter((t) => t.base === b.base).map((t) => t.tip);
    for (const l of await refSha(ctx, ["rev-list", "--parents", ...tips, `^${b.baseSha}`])) {
      const [c, ...ps] = l.split(" ");
      own.add(`${b.base}\u0000${c as string}`);
      parents.set(`${b.base}\u0000${c as string}`, ps);
    }
    for (const c of await refSha(ctx, ["rev-list", stip, `^${b.baseSha}`])) on.add(`${b.base}\u0000${c}`);
  }

  for (const t of tasks) {
    const b = t.base;
    if (!own.has(`${b}\u0000${t.tip}`)) continue; // a tip the base already has: no work of its own
    const seen = new Set<string>();
    const stack = [t.tip];
    let reached = false;
    let behind = false;
    while (stack.length > 0) {
      const c = stack.pop() as string;
      if (seen.has(c)) continue;
      seen.add(c);
      const key = `${b}\u0000${c}`;
      if (on.has(key)) {
        reached = true;
        continue;
      }
      const ps = parents.get(key) ?? [];
      // Own work unless it is a merge that only brings the base or the staging branch in.
      let mine = ps.length <= 1;
      for (let j = 1; j < ps.length; j++) {
        const p = `${b}\u0000${ps[j] as string}`;
        if (own.has(p) && !on.has(p)) mine = true;
      }
      if (mine) behind = true;
      for (let j = 0; j < ps.length; j++) {
        const p = ps[j] as string;
        const pk = `${b}\u0000${p}`;
        if (!own.has(pk) || seen.has(p)) continue;
        if (j > 0 && on.has(pk)) continue;
        stack.push(p);
      }
    }
    if (reached) out.set(t.id, behind ? "behind" : "on");
  }
  return out;
}

interface ParkedRow extends Row {
  readonly pr: string;
  readonly promote: string;
  readonly resumed: string;
}

/**
 * `jig_parked_states`: the ids that wait at the staging branch. A pull request from the branch into its base that is open
 * or merged ends parking; its own work on the staging branch is parked; so is an open pull request into the staging branch
 * (the one `pr_url` names when it goes there and, when the project lands by pull request, is not in the cache yet; else the
 * newest the cache has). A task a person took back for a fix (`park_resumed_at`) is never parked.
 */
async function parkedStates(ctx: JigCtx, staging: string, land: string, rows: readonly ParkedRow[], cache: readonly string[]): Promise<Set<string>> {
  const states = await stagingStates(ctx, staging, rows);
  // cache lines: <head> <base> <state> <ci> <fetched_at> <commit> <url> ..., newest first
  const first = new Map<string, string>();
  const byUrl = new Map<string, string>();
  const urlBase = new Map<string, string>();
  for (const line of cache) {
    const f = line.split("\t");
    const key = `${f[0] ?? ""}\u0000${f[1] ?? ""}`;
    if (!first.has(key)) first.set(key, f[2] ?? "");
    const url = f[6] ?? "";
    if (url !== "" && url !== "-" && !byUrl.has(url)) {
      byUrl.set(url, f[2] ?? "");
      urlBase.set(url, f[1] ?? "");
    }
  }
  const parked = new Set<string>();
  for (const r of rows) {
    if (r.resumed !== "" && r.resumed !== "-") continue;
    let s = first.get(`${r.branch}\u0000${r.base}`) ?? "";
    if (s === "open" || s === "merged") continue;
    const p = r.promote;
    if (p !== "" && p !== "-") {
      const st = byUrl.get(p);
      if (st === undefined) continue;
      if (st === "open" || st === "merged") continue;
    }
    if (states.get(r.id) === "on") {
      parked.add(r.id);
      continue;
    }
    const u = r.pr;
    s = "";
    if (u !== "" && u !== "-" && (!byUrl.has(u) || urlBase.get(u) === staging)) {
      if (byUrl.has(u)) s = byUrl.get(u) as string;
      else if (land === "pr") s = "open";
    } else {
      s = first.get(`${r.branch}\u0000${staging}`) ?? "";
    }
    if (s === "open") parked.add(r.id);
  }
  return parked;
}

/**
 * `_task_parked_read`: of the `ready` candidates `ids`, those parked at the staging branch. Nothing off a sound staging
 * flow. A task of an epic (its base is not the default base) ships into its epic, never into staging.
 */
export async function parkedIds(ctx: JigCtx, ids: readonly string[]): Promise<Set<string>> {
  if (ids.length === 0 || cfg(ctx, ctx.keys, "git.flow", "direct") !== "staging") return new Set();
  const staging = await stagingInUse(ctx);
  if (staging === undefined) return new Set();
  const defaultBase = cfg(ctx, ctx.keys, "git.base_branch", "main");
  const rows: ParkedRow[] = [];
  for (const id of ids) {
    if (readStateValue(ctx, id, "status") !== "ready") continue;
    const branch = readStateValue(ctx, id, "branch") ?? "";
    if (branch === "") continue;
    const base = taskBase(ctx, id);
    if (base !== defaultBase) continue;
    const dash = (k: string): string => {
      const v = readStateValue(ctx, id, k) ?? "";
      return v === "" ? "-" : v;
    };
    rows.push({ id, branch, base, pr: dash("pr_url"), promote: dash("promote_url"), resumed: dash("park_resumed_at") });
  }
  if (rows.length === 0) return new Set();
  const land = cfg(ctx, ctx.keys, "git.staging_land", "pr");
  return parkedStates(ctx, staging, land, rows, await readForgeCache(ctx));
}

