// The one place a process is started.
//
// Only this module imports node:child_process (test/architecture.test.ts holds that).
// A caller names one of three programs and hands over arguments as an array: there is
// no shell, so no quoting and no injection. Output is bytes, because a path git prints
// need not be UTF-8; `text()` decodes on request.

import { spawn } from "node:child_process";
import type { Ctx } from "./context.ts";
import { JigError } from "./errors.ts";

export type ExecCmd = "git" | "gh" | "glab";

export interface ExecResult {
  readonly code: number;
  readonly stdout: Buffer;
  readonly stderr: Buffer;
}

export interface ExecOpts {
  readonly cwd?: string;
  /** Variables added to (or, with `undefined`, removed from) the child's environment. */
  readonly env?: Readonly<Record<string, string | undefined>>;
  readonly input?: string | Buffer;
}

export type ExecFn = (cmd: ExecCmd, args: readonly string[], opts?: ExecOpts) => Promise<ExecResult>;

// jig_clear_git_location_env (scripts/lib/common.sh): Jig decides which repository it is
// in from where it was started, not from what the environment says.
const GIT_LOCATION_ENV = [
  "GIT_DIR",
  "GIT_WORK_TREE",
  "GIT_COMMON_DIR",
  "GIT_OBJECT_DIRECTORY",
  "GIT_ALTERNATE_OBJECT_DIRECTORIES",
  "GIT_INDEX_FILE",
  "GIT_NAMESPACE",
  "GIT_CEILING_DIRECTORIES",
  "GIT_DISCOVERY_ACROSS_FILESYSTEM",
];

const ALLOWED: readonly string[] = ["git", "gh", "glab"];

function childEnv(extra: ExecOpts["env"]): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  for (const name of GIT_LOCATION_ENV) delete env[name];
  for (const [name, value] of Object.entries(extra ?? {})) {
    if (value === undefined) delete env[name];
    else env[name] = value;
  }
  return env;
}

export const exec: ExecFn = (cmd, args, opts = {}) => {
  if (!ALLOWED.includes(cmd)) {
    return Promise.reject(new JigError("failed", `exec: '${String(cmd)}' is not a program Jig starts`));
  }
  return new Promise<ExecResult>((resolve, reject) => {
    const child = spawn(cmd, [...args], {
      cwd: opts.cwd,
      env: childEnv(opts.env),
      shell: false,
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => out.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => err.push(chunk));
    child.on("error", (e) => reject(new JigError("failed", `cannot run ${cmd}: ${e.message}`)));
    child.on("close", (code, signal) => {
      resolve({
        code: code ?? (signal ? 128 : 1),
        stdout: Buffer.concat(out),
        stderr: Buffer.concat(err),
      });
    });
    // A child that exits before reading its input closes the pipe: not an error here.
    child.stdin.on("error", () => {});
    child.stdin.end(opts.input);
  });
};

/** `git -c core.fsmonitor=false -C <dir> <args>`: every git read of the core. */
export function git(ctx: Pick<Ctx, "exec">, dir: string, args: readonly string[], opts?: ExecOpts): Promise<ExecResult> {
  return ctx.exec("git", ["-c", "core.fsmonitor=false", "-C", dir, ...args], opts);
}

/** The stdout of a result as UTF-8 text. */
export function text(buf: Buffer): string {
  return buf.toString("utf8");
}

// --- the test double ----------------------------------------------------------

export interface FakeAnswer {
  readonly cmd: ExecCmd;
  readonly args: readonly string[];
  readonly code?: number;
  readonly stdout?: string | Buffer;
  readonly stderr?: string | Buffer;
}

export interface FakeCall {
  readonly cmd: ExecCmd;
  readonly args: readonly string[];
  readonly opts: ExecOpts | undefined;
}

export interface FakeExec {
  readonly exec: ExecFn;
  /** Every call, in order, answered or not. */
  readonly calls: FakeCall[];
}

function key(cmd: string, args: readonly string[]): string {
  return JSON.stringify([cmd, ...args]);
}

/**
 * A process runner for tests: answers by exact argv, throws on any call it was not given an
 * answer for, and logs every call (the way bash tests log what a stub was asked).
 */
export function fakeExec(table: readonly FakeAnswer[]): FakeExec {
  const answers = new Map<string, FakeAnswer>();
  for (const a of table) answers.set(key(a.cmd, a.args), a);
  const calls: FakeCall[] = [];
  const run: ExecFn = (cmd, args, opts) => {
    calls.push({ cmd, args, opts });
    const a = answers.get(key(cmd, args));
    if (!a) return Promise.reject(new Error(`fakeExec: unexpected call: ${cmd} ${args.join(" ")}`));
    return Promise.resolve({
      code: a.code ?? 0,
      stdout: Buffer.from(a.stdout ?? ""),
      stderr: Buffer.from(a.stderr ?? ""),
    });
  };
  return { exec: run, calls };
}
