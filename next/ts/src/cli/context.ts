// `jig context`: the command line of it. The words after `context` are read here (cmd_context and
// ctx_stateless in scripts/lib/context.sh); what they ask for is core/context/.

import type { JigCtx, Output } from "../core/context.ts";
import { die } from "../core/errors.ts";
import { resolveContext } from "../core/context/resolve.ts";
import { resolveSelectors } from "../core/context/selectors.ts";
import type { RawSelectors } from "../core/context/selectors.ts";
import { statelessContext } from "../core/context/stateless.ts";
import { validStage } from "../core/context/selectors.ts";
import type { AcknowledgeOptions } from "../core/context/ledger.ts";
import { acknowledge, guard, pending } from "../core/context/ledger.ts";
import type { Format, StatelessOptions } from "../core/context/stateless.ts";

export const CTX_USAGE = `usage: jig context [--task <id>] [--files <list>|-] [--domains a,b] [--all] [--format list|paths]
       jig context resolve   [selectors] [--catalog]
       jig context pending   [selectors]
       jig context guard     [selectors]
       jig context acknowledge --task <id> [--stage <stage> | --revoke] --files <list>|-

selectors: --task <id>|--no-task --stage <stage> --files <list>|- --domains a,b --topics a,b --ids a,b --all`;


function parseStateless(args: readonly string[]): StatelessOptions {
  let task = "";
  let noTask = false;
  let filesArg = "";
  let filesStdin = false;
  let domainsArg = "";
  let all = false;
  let format: Format = "list";
  const value = (i: number, flag: string): string => {
    if (args.length - i < 2) throw die(`context: ${flag} requires a value`);
    return args[i + 1] as string;
  };
  for (let i = 0; i < args.length; ) {
    const a = args[i] as string;
    switch (a) {
      case "--task":
        task = value(i, a);
        i += 2;
        break;
      case "--no-task":
        noTask = true;
        i += 1;
        break;
      case "--stage":
        throw die("context: --stage requires the progressive form; use jig context resolve");
      case "--files": {
        const v = value(i, a);
        if (v === "-") filesStdin = true;
        else filesArg = v;
        i += 2;
        break;
      }
      case "--domains":
        domainsArg = value(i, a);
        i += 2;
        break;
      case "--all":
        all = true;
        i += 1;
        break;
      case "--format": {
        const v = value(i, a);
        if (v !== "list" && v !== "paths") throw die(`context: invalid --format: ${v} (want list or paths)`);
        format = v;
        i += 2;
        break;
      }
      default:
        throw die(`context: unknown argument: ${a}`);
    }
  }
  return { task, noTask, filesArg, filesStdin, domainsArg, all, format };
}

/** `_ctx_parse_selectors`: the words of `resolve`, `pending` and `guard`. */
export function parseSelectorArgs(args: readonly string[]): RawSelectors {
  let task = "";
  let noTask = false;
  let stage = "";
  let filesArg = "";
  let filesStdin = false;
  let domainsArg = "";
  let topics = "";
  let ids = "";
  let catalog = false;
  let all = false;
  const value = (i: number, flag: string): string => {
    if (args.length - i < 2) throw die(`context: ${flag} requires a value`);
    return args[i + 1] as string;
  };
  for (let i = 0; i < args.length; ) {
    const a = args[i] as string;
    switch (a) {
      case "--task":
        task = value(i, a);
        i += 2;
        break;
      case "--no-task":
        noTask = true;
        i += 1;
        break;
      case "--stage": {
        const v = value(i, a);
        if (!validStage(v)) throw die(`context: invalid stage: ${v}`);
        stage = v;
        i += 2;
        break;
      }
      case "--files": {
        const v = value(i, a);
        if (v === "-") filesStdin = true;
        else filesArg = v;
        i += 2;
        break;
      }
      case "--domains":
        domainsArg = value(i, a);
        i += 2;
        break;
      case "--topics":
        topics = value(i, a).replaceAll(",", " ");
        i += 2;
        break;
      case "--ids":
        ids = value(i, a).replaceAll(",", " ");
        i += 2;
        break;
      case "--catalog":
        catalog = true;
        i += 1;
        break;
      case "--all":
        all = true;
        i += 1;
        break;
      default:
        throw die(`context: unknown argument: ${a}`);
    }
  }
  return { task, noTask, stage, filesArg, filesStdin, domainsArg, topics, ids, catalog, all };
}

/** `ctx_acknowledge`'s words. */
function parseAcknowledge(args: readonly string[]): AcknowledgeOptions {
  let task = "";
  let filesArg = "";
  let filesStdin = false;
  let stage = "";
  let revoke = false;
  const value = (i: number, flag: string): string => {
    if (args.length - i < 2) throw die(`context: ${flag} requires a value`);
    return args[i + 1] as string;
  };
  for (let i = 0; i < args.length; ) {
    const a = args[i] as string;
    switch (a) {
      case "--task":
        task = value(i, a);
        i += 2;
        break;
      case "--files": {
        const v = value(i, a);
        if (v === "-") filesStdin = true;
        else filesArg = v;
        i += 2;
        break;
      }
      case "--stage": {
        const v = value(i, a);
        if (!validStage(v)) throw die(`context: invalid stage: ${v}`);
        stage = v;
        i += 2;
        break;
      }
      case "--revoke":
        revoke = true;
        i += 1;
        break;
      default:
        throw die(`context: unknown argument: ${a}`);
    }
  }
  if (revoke && stage !== "") {
    throw die("context acknowledge: --revoke takes no --stage: a revoke withdraws the path's acknowledgement whatever stage it was made at");
  }
  return { task, filesArg, filesStdin, stage, revoke };
}

/** `cmd_context`, after the project is known to be initialised. Returns the exit status. */
export async function runContext(ctx: JigCtx, args: readonly string[], stdin: () => Promise<string>, out: Output): Promise<number> {
  const first = args[0] ?? "";
  if (first === "pending" || first === "guard") {
    const selectors = await resolveSelectors(ctx, parseSelectorArgs(args.slice(1)), stdin, out);
    if (first === "guard") return guard(ctx, selectors, out);
    await pending(ctx, selectors, out);
    return 0;
  }
  if (first === "acknowledge") {
    await acknowledge(ctx, parseAcknowledge(args.slice(1)), stdin, out);
    return 0;
  }
  if (first === "resolve") {
    const selectors = await resolveSelectors(ctx, parseSelectorArgs(args.slice(1)), stdin, out);
    return resolveContext(ctx, selectors, out);
  }
  if (first !== "" && !first.startsWith("-")) throw die(CTX_USAGE);
  await statelessContext(ctx, parseStateless(args), stdin, out);
  return 0;
}
