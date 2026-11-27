// The dispatcher's prelude, `jig_checkout_record`: before a working command runs, say that a session is
// working here (adr-20260924-a-checkout-records-what-is-happening-in-it). Three records, all under the
// clone's gitignored `.ai/runtime/`:
//
//   <checkout>/.ai/runtime/checkout        what this checkout last ran
//   <checkout>/.ai/runtime/working/<name>  one file per piece of work in progress here
//   <clone root>/.ai/runtime/taken/<task>/<session>  which session works which task
//
// Nothing here may fail a command or print: every step gives up quietly, as bash's `|| true` does.
// Ported from scripts/lib/checkout.sh (`_jig_checkout_record_inner`, `_jig_checkout_take`,
// `_jig_checkout_revive`) for the words a `context` call reaches; `jig_record_changed`'s second half,
// the redraw of the status page, is not ported (neither skeleton has a status page).

import path from "node:path";
import { nowUtc } from "../clock.ts";
import type { JigCtx } from "../context.ts";
import { currentBranch, worktreeList } from "../git/read.ts";
import {
  ensureDir,
  isDirectory,
  mtimeSeconds,
  recordLines,
  recordValue,
  runtimeDir,
  takenDir,
  takenRecordsOf,
  writeRecord,
} from "../storage/checkout.ts";
import { cfg } from "../storage/config.ts";
import { revisionBump } from "../storage/revision.ts";
import { stateFile, validTaskId } from "../storage/state-read.ts";
import { hasState, taskIdsWithState } from "../storage/tasks.ts";
import { checkoutSession } from "./session.ts";

/** `jig_duration_seconds` for the busy window; the default stands for anything it refuses. */
function ttlSeconds(ctx: JigCtx): number {
  const raw = cfg(ctx, ctx.keys, "checkout.busy_ttl", "12h");
  const m = /^([0-9]+)([dhms]?)$/.exec(raw);
  if (m === null) return 43200;
  const n = Number(m[1]);
  switch (m[2]) {
    case "h":
      return n * 3600;
    case "m":
      return n * 60;
    case "s":
      return n;
    default:
      return n * 86400;
  }
}

function stateOf(ctx: JigCtx, id: string): string {
  return stateFile(ctx, id);
}

/** Rule 1 of the name: a task the arguments name, unless its branch is checked out in another worktree. */
async function nameFromArgs(ctx: JigCtx, head: string, words: readonly string[]): Promise<string | undefined> {
  let list: string | undefined;
  for (const a of words) {
    if (a.startsWith("-")) continue;
    if (!validTaskId(a) || !hasState(ctx, a)) continue;
    list ??= await worktreeList(ctx);
    const branch = recordValue(stateOf(ctx, a), "branch") ?? "";
    const elsewhere = branch !== "" && list !== "" && branch !== head && list.split("\n").includes(`branch refs/heads/${branch}`);
    if (elsewhere) continue;
    return a;
  }
  return undefined;
}

/** Rule 2: the live task whose branch is checked out here. */
function nameFromHead(ctx: JigCtx, head: string): string | undefined {
  if (head === "") return undefined;
  for (const id of taskIdsWithState(ctx)) {
    if ((recordValue(stateOf(ctx, id), "branch") ?? "") !== head) continue;
    const status = recordValue(stateOf(ctx, id), "status") ?? "";
    if (status === "active" || status === "ready") return id;
  }
  return undefined;
}

/** `_jig_checkout_works`: the task a `context` call works: the first argument that is a valid id with a workspace. */
function taskWorked(ctx: JigCtx, rest: readonly string[]): string | undefined {
  for (const a of rest) {
    if (a.startsWith("-")) continue;
    if (!validTaskId(a) || !hasState(ctx, a)) continue;
    return a;
  }
  return undefined;
}

/** `_jig_checkout_take`: this session's record for the task the command works. Nothing without a session id. */
function take(ctx: JigCtx, words: readonly string[], session: string): void {
  const id = words[0] === "context" ? taskWorked(ctx, words.slice(1)) : undefined;
  if (id === undefined || session === "") return;
  const dir = path.join(takenDir(ctx), id);
  if (!isDirectory(dir) && !ensureDir(dir)) return;
  const file = path.join(dir, session);
  let since = "";
  const old = recordValue(file, "since");
  if (old !== undefined) {
    since = old;
    const mtime = mtimeSeconds(file);
    // against a file's mtime: the real clock
    const age = mtime === undefined ? undefined : Math.floor(Date.now() / 1000) - mtime;
    if (age === undefined || age > ttlSeconds(ctx)) since = "";
  }
  if (since === "") since = nowUtc(ctx.clock);
  const cmd = words.join(" ").replaceAll("\n", " ").replaceAll("\t", " ");
  if (!writeRecord(file, `checkout: ${ctx.root}\nsince: ${since}\ncommand: ${cmd}\n`)) return;
  revisionBump(ctx.root, ctx.clock);
}

/** `_jig_checkout_revive`: a session that goes on after its end was marked takes the mark off its own taken records. */
function revive(ctx: JigCtx, session: string): void {
  if (session === "") return;
  for (const f of takenRecordsOf(ctx, session)) {
    if (recordValue(f, "ended") === undefined) continue;
    const body = recordLines(f)
      .filter((l) => !l.startsWith("ended: "))
      .map((l) => `${l}\n`)
      .join("");
    writeRecord(f, body);
    revisionBump(ctx.root, ctx.clock);
  }
}

async function recordInner(ctx: JigCtx, words: readonly string[]): Promise<void> {
  const runtime = runtimeDir(ctx);
  if (!isDirectory(runtime) && !ensureDir(runtime)) return;
  const head = (await currentBranch(ctx)) ?? "";

  // The checkout's own record; `branch_reported` is carried over untouched.
  const told = recordValue(path.join(runtime, "checkout"), "branch_reported") ?? "";
  let body = `command: ${words.join(" ")}\n`;
  if (told !== "") body += `branch_reported: ${told}\n`;
  writeRecord(path.join(runtime, "checkout"), body);

  const session = checkoutSession(ctx);
  take(ctx, words, session);
  revive(ctx, session);

  const name = (await nameFromArgs(ctx, head, words)) ?? nameFromHead(ctx, head) ?? session;
  if (name === "" || !validTaskId(name)) return;
  const working = path.join(runtime, "working");
  if (!isDirectory(working) && !ensureDir(working)) return;
  const cmd = words.join(" ").replaceAll("\n", " ").replaceAll("\r", " ");
  let record = `command: ${cmd}\n`;
  if (session !== "" && session !== name) record += `session: ${session}\n`;
  writeRecord(path.join(working, name), record);
}

/**
 * `jig_checkout_record <command-words...>`: writes at most three records and prints nothing. `ctx.root` is
 * the repository root and the project must hold `.ai/config.yaml` (the recorder is quiet where `jig_require_init` would die).
 * Skipped under JIG_INTERNAL_REDRAW.
 */
export async function recordCheckout(ctx: JigCtx, words: readonly string[]): Promise<void> {
  if ((ctx.env["JIG_INTERNAL_REDRAW"] ?? "") !== "") return;
  try {
    await recordInner(ctx, words);
  } catch {
    // a record that cannot be written never fails the command
  }
}
