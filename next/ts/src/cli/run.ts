// The command line: argv in, text out, an exit status back. Everything process-global (stdout, exit,
// the environment, where the program lives) is handed in, so a test drives it without a process.
// The core never imports this directory.

import { checkJigNow, nowUtc, systemClock } from "../core/clock.ts";
import type { Env } from "../core/clock.ts";
import type { Ctx } from "../core/context.ts";
import { JigError } from "../core/errors.ts";
import { exec } from "../core/exec.ts";
import { jigVersion } from "../core/version.ts";
import { findScriptsLib } from "../core/storage/framework.ts";

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
}

const USAGE = `jig — TypeScript skeleton (not a release; the commands are in scripts/jig)

Usage: jig <command> [args]

  version            print the version, as \`jig --version\` does
  help               print this text

No other command is ported yet.
`;

function usage(): string {
  return USAGE;
}

async function versionLine(opts: RunOpts, args: readonly string[]): Promise<string> {
  if (args.length > 0) throw new JigError("failed", `version: unknown option: ${args[0]}`);
  const ctx: Ctx = { root: opts.cwd, exec, clock: systemClock(opts.env), env: opts.env };
  const lib = findScriptsLib(opts.entryDir);
  let v: string | undefined;
  if (lib !== undefined) v = await jigVersion(ctx, lib);
  else v = opts.bakedVersion;
  if (v === undefined || v === "") throw new JigError("failed", "cannot tell the version: the framework's scripts/lib/version.sh was not found");
  return `jig ${v}\n`;
}

function envelopeError(env: Env, err: JigError): string {
  const clock = systemClock(env);
  // `revision` is the clone's write counter (schemas/json.md); it is not read yet, so 0.
  return `${JSON.stringify({ schema: 1, revision: 0, generated_at: nowUtc(clock), error: { code: err.code, message: err.message } })}\n`;
}

/** Runs one command line; returns the exit status. */
export async function run(opts: RunOpts): Promise<number> {
  const { io } = opts;
  const [first, ...rest] = opts.argv;
  const cmd = first ?? "help";
  const json = opts.argv.includes("--json");
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
      default:
        if (json) throw new JigError("usage", `${cmd}: not available in the TypeScript skeleton`);
        io.err(usage());
        throw new JigError("failed", `unknown command: ${cmd}`);
    }
  } catch (e) {
    const err = e instanceof JigError ? e : new JigError("failed", e instanceof Error ? e.message : String(e));
    if (json) {
      try {
        io.out(envelopeError(opts.env, err));
      } catch {
        io.out(envelopeError({}, err));
      }
    } else {
      io.err(`jig: error: ${err.message}\n`);
    }
    return 1;
  }
}
