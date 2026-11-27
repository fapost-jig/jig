// The command line: argv in, text out, an exit status back. Everything process-global (stdout, exit,
// the environment, where the program lives) is handed in, so a test drives it without a process.
// The core never imports this directory.

import { checkJigNow, nowUtc, systemClock } from "../core/clock.ts";
import type { Env } from "../core/clock.ts";
import type { Ctx, JigCtx } from "../core/context.ts";
import { recordCheckout } from "../core/checkout/record.ts";
import { JigError } from "../core/errors.ts";
import { exec as realExec } from "../core/exec.ts";
import type { ExecFn } from "../core/exec.ts";
import { jigVersion } from "../core/version.ts";
import { findScriptsLib, readLocalKeyLists } from "../core/storage/framework.ts";
import { isInitialised, projectRoot, revisionAt } from "../core/storage/project.ts";
import { runContext } from "./context.ts";

export interface Io {
  out(text: string): void;
  err(text: string): void;
}

export interface RunOpts {
  readonly argv: readonly string[];
  readonly env: Env;
  readonly cwd: string;
  /** The directory the program runs from; the framework is found by walking up from it. */
  readonly entryDir: string;
  /** The version to print when no framework directory is found (baked into a bundle). */
  readonly bakedVersion?: string | undefined;
  readonly io: Io;
  /** The process runner; the real one when absent. Tests hand in a fake. */
  readonly exec?: ExecFn | undefined;
  /** Everything on standard input, read when a command asks for it (`--files -`); empty when not given. */
  readonly stdin?: (() => Promise<string>) | undefined;
}

const USAGE = `jig — TypeScript skeleton (not a release; the commands are in scripts/jig)

Usage: jig <command> [args]

  version            print the version, as \`jig --version\` does
  context [options]  the knowledge that matches a change (the stateless form only)
  help               print this text

No other command is ported yet.
`;

function usage(): string {
  return USAGE;
}

async function versionLine(opts: RunOpts, args: readonly string[]): Promise<string> {
  if (args.length > 0) throw new JigError("failed", `version: unknown option: ${args[0]}`);
  const ctx: Ctx = { root: opts.cwd, exec: opts.exec ?? realExec, clock: systemClock(opts.env), env: opts.env };
  const lib = findScriptsLib(opts.entryDir);
  let v: string | undefined;
  if (lib !== undefined) v = await jigVersion(ctx, lib);
  else v = opts.bakedVersion;
  if (v === undefined || v === "") throw new JigError("failed", "cannot tell the version: the framework's scripts/lib/version.sh was not found");
  return `jig ${v}\n`;
}

function envelopeError(env: Env, revision: number, err: JigError): string {
  const clock = systemClock(env);
  return `${JSON.stringify({ schema: 1, revision, generated_at: nowUtc(clock), error: { code: err.code, message: err.message } })}\n`;
}

/**
 * The project a command that works on one runs in. The dispatcher's prelude, the checkout recorder, runs first and is
 * quiet where `jig_require_init` would complain; then `jig_require_init` itself.
 */
async function projectContext(opts: RunOpts, words: readonly string[]): Promise<JigCtx> {
  const lib = findScriptsLib(opts.entryDir);
  const keys = readLocalKeyLists(lib === undefined ? "" : `${lib}/config.sh`);
  const base: Ctx = { root: opts.cwd, exec: opts.exec ?? realExec, clock: systemClock(opts.env), env: opts.env };
  const root = await projectRoot(base, opts.cwd);
  if (root === undefined) throw new JigError("not-a-repository", "not inside a git repository");
  const ctx: JigCtx = { ...base, root, keys, lib };
  if (!isInitialised(root)) throw new JigError("not-initialised", "project is not initialised; run: jig init");
  await recordCheckout(ctx, words);
  return ctx;
}

/** Runs one command line; returns the exit status. */
export async function run(opts: RunOpts): Promise<number> {
  const { io } = opts;
  const [first, ...rest] = opts.argv;
  const cmd = first ?? "help";
  const json = opts.argv.includes("--json");
  // `revision` is the clone's write counter (schemas/json.md). Like json_run, read it before the
  // command runs, never after; 0 when `cwd` is not in a repository (or git cannot say).
  const revision = json ? await revisionAt({ exec: opts.exec ?? realExec }, opts.cwd) : 0;
  try {
    // A malformed JIG_NOW is refused once, before any command; a `--json` command refuses it in its envelope.
    checkJigNow(opts.env);
    switch (cmd) {
      case "help":
      case "-h":
      case "--help":
        io.out(usage());
        return 0;
      case "version":
      case "--version":
        if (json) throw new JigError("usage", "version --json is not available in the TypeScript skeleton");
        io.out(await versionLine(opts, rest));
        return 0;
      case "context": {
        if (json) throw new JigError("usage", `${cmd}: not available in the TypeScript skeleton`);
        const ctx = await projectContext(opts, ["context", ...rest]);
        return await runContext(ctx, rest, opts.stdin ?? (() => Promise.resolve("")), io);
      }
      default:
        if (json) throw new JigError("usage", `${cmd}: not available in the TypeScript skeleton`);
        io.err(usage());
        throw new JigError("failed", `unknown command: ${cmd}`);
    }
  } catch (e) {
    const err = e instanceof JigError ? e : new JigError("failed", e instanceof Error ? e.message : String(e));
    if (json) {
      try {
        io.out(envelopeError(opts.env, revision, err));
      } catch {
        io.out(envelopeError({}, revision, err));
      }
    } else {
      io.err(`jig: error: ${err.message}\n`);
    }
    return 1;
  }
}
