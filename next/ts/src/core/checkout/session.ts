// The runtime's id for the session running this command (`jig_checkout_session`): the one adapter that
// answers names it from the environment. The adapters live in the framework source; where none is
// reachable, or none answers, the session has no id.

import type { JigCtx } from "../context.ts";
import { adapterPresent, adaptersDir } from "../storage/adapters.ts";
import { cfg } from "../storage/config.ts";
import { validTaskId } from "../storage/state-read.ts";

/** `cfg_list`: brackets dropped, commas as spaces, the words between runs of spaces. */
function configWords(value: string): string[] {
  return value.replaceAll("[", "").replaceAll("]", "").replaceAll(",", " ").split(" ").filter((w) => w !== "");
}

/** `_adapters_valid_name`. */
function validAdapterName(name: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(name);
}

/**
 * The session id, or "". Only `claude` answers (`adapter_claude_session_id`: CLAUDE_CODE_SESSION_ID);
 * `codex` does not, and an adapter this port does not know is skipped as bash skips one without the function.
 */
export function checkoutSession(ctx: JigCtx): string {
  const dir = adaptersDir(ctx, ctx.lib);
  if (dir === undefined) return "";
  for (const name of configWords(cfg(ctx, ctx.keys, "adapters", "claude codex"))) {
    if (!validAdapterName(name)) return "";
    if (!adapterPresent(dir, name)) continue;
    if (name !== "claude") continue;
    const id = ctx.env["CLAUDE_CODE_SESSION_ID"] ?? "";
    if (id === "" || !validTaskId(id)) continue;
    return id;
  }
  return "";
}
