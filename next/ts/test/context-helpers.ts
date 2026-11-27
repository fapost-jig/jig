// Shared by the context-*.test.ts files: a project on disk and the command line run in-process.
//
// The process runner is a fake by default (`fakeGit`: a closed table of the git calls a `context` call makes, answered
// from the options a test gives, and a refusal of any call it does not know). A project made with `real: true` (it has a
// repository on disk) is run with the real git instead; those are the integration tests the other files name in their
// headers. The files of the project are real either way: only the processes are replaced.

import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { run } from "../src/cli/run.ts";
import type { ExecFn, ExecResult } from "../src/core/exec.ts";
import { cleanEnv, makeProject, packageRoot, proc, tmpDir } from "./helpers.ts";

export interface Result {
  code: number;
  out: string;
  err: string;
}

export interface FakeGitOpts {
  /** The branch checked out; null for a detached HEAD. Default `main`. */
  readonly branch?: string | null;
  /** `git worktree list --porcelain`; by default only this checkout. */
  readonly worktrees?: string;
  /** Refs that exist (`refs/heads/main`, ...); by default none, so there is no base branch. */
  readonly refs?: readonly string[];
  readonly mergeBase?: string;
  readonly diffBase?: readonly string[];
  readonly cached?: readonly string[];
  readonly unstaged?: readonly string[];
  readonly untracked?: readonly string[];
  /** Further answers by the argv after `-C <dir>`, joined by spaces (`rev-list S ^B`); stdout. `check-ref-format` is accepted by default. */
  readonly answers?: Readonly<Record<string, string>>;
  /** `git rev-parse --show-toplevel` fails: the directory is no repository. */
  readonly notARepository?: boolean;
}

export interface FakeGit {
  readonly exec: ExecFn;
  /** Every call, as the argv after `-c core.fsmonitor=false -C <dir>`. */
  readonly calls: string[];
}

function ok(stdout: string): ExecResult {
  return { code: 0, stdout: Buffer.from(stdout), stderr: Buffer.alloc(0) };
}

function no(): ExecResult {
  return { code: 1, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) };
}

const lines = (l: readonly string[] | undefined): string => (l ?? []).map((x) => `${x}\n`).join("");

/** The git calls of a `context` call, answered from the options; any other call is an error. */
export function fakeGit(root: string, o: FakeGitOpts = {}): FakeGit {
  const calls: string[] = [];
  const branch = o.branch === undefined ? "main" : o.branch;
  const exec: ExecFn = (cmd, args, opts) => {
    if (cmd !== "git" || args[0] !== "-c" || args[1] !== "core.fsmonitor=false" || args[2] !== "-C") {
      return Promise.reject(new Error(`fakeGit: unexpected ${cmd} call: ${args.join(" ")}`));
    }
    const dir = args[3] as string;
    const rest = args.slice(4);
    const key = rest.join(" ");
    calls.push(key);
    let r: ExecResult | undefined;
    if (key === "rev-parse --show-toplevel") r = o.notARepository === true ? { code: 128, stdout: Buffer.alloc(0), stderr: Buffer.from("fatal: not a git repository\n") } : ok(`${root}\n`);
    else if (key === "symbolic-ref --quiet --short HEAD") r = branch === null ? no() : ok(`${branch}\n`);
    else if (o.answers !== undefined && key in o.answers) r = ok(o.answers[key] as string);
    else if (rest[0] === "check-ref-format") r = ok("");
    else if (key === "worktree list --porcelain") r = ok(o.worktrees ?? `worktree ${root}\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/${branch ?? "x"}\n\n`);
    else if (key === "rev-parse --absolute-git-dir") r = ok(`${root}/.git\n`);
    else if (rest[0] === "rev-parse" && rest[1] === "--verify" && rest[2] === "--quiet") {
      const ref = (rest[3] as string).replace(/\^\{commit\}$/, "");
      r = (o.refs ?? []).includes(ref) ? ok("1111111111111111111111111111111111111111\n") : no();
    } else if (rest[0] === "merge-base") r = o.mergeBase === undefined ? no() : ok(`${o.mergeBase}\n`);
    else if (rest[0] === "diff" && rest[1] === "--name-only" && rest.length === 3) r = ok(lines(o.diffBase));
    else if (key === "diff --cached --name-only") r = ok(lines(o.cached));
    else if (key === "diff --name-only") r = ok(lines(o.unstaged));
    else if (key === "ls-files --others --exclude-standard") r = ok(lines(o.untracked));
    else if (key === "hash-object --no-filters --stdin-paths") {
      // the blob hash git would give each file named on stdin, read from the directory the call runs in
      const names = String(opts?.input ?? "").split("\n").filter((n) => n !== "");
      r = ok(
        names
          .map((n) => {
            const body = fs.readFileSync(path.join(dir, n));
            return `${createHash("sha1").update(`blob ${body.length}\0`).update(body).digest("hex")}\n`;
          })
          .join(""),
      );
    }
    return r === undefined ? Promise.reject(new Error(`fakeGit: unexpected git call: ${key}`)) : Promise.resolve(r);
  };
  return { exec, calls };
}

/**
 * Runs `jig context <args>` in-process in `cwd`. The process runner is the real one when `cwd` is a repository on disk
 * (a project made with `real: true`), else `git` (a fake answering as `FakeGitOpts` says); `git` also returns the call log.
 */
export function jigContext(cwd: string, args: readonly string[], env: Record<string, string> = {}, stdin = "", git?: FakeGit): Promise<Result> {
  const exec = git?.exec ?? (fs.existsSync(path.join(cwd, ".git")) ? undefined : fakeGit(cwd).exec);
  let out = "";
  let err = "";
  const e = { HOME: cwd, JIG_NOW: "1795788180", ...env };
  return run({
    argv: ["context", ...args],
    env: e,
    cwd,
    entryDir: path.join(packageRoot, "src", "cli"),
    exec,
    io: { out: (t) => (out += t), err: (t) => (err += t) },
    stdin: () => Promise.resolve(stdin),
  }).then((code) => ({ code, out, err }));
}

export function write(dir: string, rel: string, text: string): void {
  fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
  fs.writeFileSync(path.join(dir, rel), text);
}

/**
 * A project with the three global documents. A repository on disk (`git init`, a commit) only when `real` is true;
 * otherwise a directory with `.ai/config.yaml`, which the fake git stands for.
 */
export function knowledgeProject(t: { after(fn: () => void): void }, config = "git.base_branch: main\n", real = false): string {
  let dir: string;
  if (real) dir = makeProject(tmpDir(t), config);
  else {
    dir = tmpDir(t);
    write(dir, ".ai/config.yaml", config);
  }
  for (const g of ["GLOSSARY.md", "ARCHITECTURE.md", "RULES.md"]) write(dir, `.ai/knowledge/${g}`, `# ${g}\n`);
  return dir;
}

export function doc(dir: string, rel: string, front: Record<string, string | string[]>): void {
  const lines = ["---"];
  for (const [k, v] of Object.entries(front)) {
    if (Array.isArray(v)) {
      lines.push(`${k}:`, ...v.map((i) => `  - "${i}"`));
    } else lines.push(`${k}: ${v}`);
  }
  lines.push("---", "");
  write(dir, `.ai/knowledge/${rel}`, lines.join("\n"));
}

export function task(dir: string, id: string, state: Record<string, string>): void {
  write(dir, `.ai/workspace/tasks/${id}/state`, Object.entries(state).map(([k, v]) => `${k}: ${v}\n`).join(""));
  write(dir, `.ai/workspace/tasks/${id}/task.md`, `# ${id}\n`);
}

export function git(dir: string, ...args: string[]): void {
  const r = proc("git", args, { cwd: dir, env: cleanEnv({ HOME: dir }) });
  if (r.code !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
}
