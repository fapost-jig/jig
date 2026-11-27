// Shared by the tests. The tests may start processes themselves (bash, git, node): the rule that only
// core/exec.ts imports node:child_process holds for src/, not for the checks of it.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { systemClock } from "../src/core/clock.ts";
import type { Ctx } from "../src/core/context.ts";
import { exec } from "../src/core/exec.ts";

export const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const repoRoot = path.resolve(packageRoot, "..", "..");
export const jigBin = path.join(repoRoot, "scripts", "jig");

export interface Proc {
  code: number;
  stdout: string;
  stderr: string;
}

/** A clean environment for child processes: no inherited JIG_*, a fixed time zone, git identity and locale. */
export function cleanEnv(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const name of ["PATH", "SystemRoot", "TMPDIR", "TEMP", "TMP"]) {
    const v = process.env[name];
    if (v !== undefined) env[name] = v;
  }
  return {
    ...env,
    TZ: "UTC",
    LC_ALL: "C.UTF-8",
    GIT_AUTHOR_NAME: "jig-tests",
    GIT_AUTHOR_EMAIL: "tests@jig.invalid",
    GIT_COMMITTER_NAME: "jig-tests",
    GIT_COMMITTER_EMAIL: "tests@jig.invalid",
    GIT_CONFIG_NOSYSTEM: "1",
    ...extra,
  };
}

export function proc(cmd: string, args: readonly string[], opts: { cwd?: string; env?: NodeJS.ProcessEnv; input?: string } = {}): Proc {
  const r = spawnSync(cmd, [...args], {
    cwd: opts.cwd,
    env: opts.env ?? cleanEnv(),
    input: opts.input,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.error) throw r.error;
  return { code: r.status ?? 128, stdout: r.stdout, stderr: r.stderr };
}

/** A temporary directory removed with the test; its real path (macOS /var is a link). */
export function tmpDir(t: { after(fn: () => void): void }, prefix = "jig-ts-"): string {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

/** A git repository with one commit, and `.ai/config.yaml` so that Jig takes it for its own. */
export function makeProject(dir: string, config = "git.base_branch: main\n"): string {
  const env = cleanEnv({ HOME: dir });
  proc("git", ["init", "-q", "-b", "main", "."], { cwd: dir, env });
  proc("git", ["commit", "-q", "--allow-empty", "-m", "init"], { cwd: dir, env });
  fs.mkdirSync(path.join(dir, ".ai"), { recursive: true });
  fs.writeFileSync(path.join(dir, ".ai", "config.yaml"), config);
  return dir;
}

export function ctxFor(root: string, env: Record<string, string> = {}): Ctx {
  return { root, exec, clock: systemClock(env), env };
}

/** The bash `jig`, run from the framework checkout this test lives in, against the project `cwd`. */
export function bashJig(cwd: string, args: readonly string[], env: Record<string, string> = {}): Proc {
  return proc("bash", [jigBin, ...args], { cwd, env: cleanEnv({ HOME: cwd, ...env }) });
}

const FRAMEWORK = `
set -eu
export JIG_LIB="$JIG_HOME/scripts/lib"
. "$JIG_LIB/version.sh"
. "$JIG_LIB/common.sh"
. "$JIG_LIB/config.sh"
`;

/** Runs a bash body with the framework's libraries sourced; the body can use $JIG_HOME. */
export function bashLib(cwd: string, body: string, args: readonly string[] = [], env: Record<string, string> = {}): Proc {
  return proc("bash", ["-c", `${FRAMEWORK}\n${body}`, "bash", ...args], {
    cwd,
    env: cleanEnv({ HOME: cwd, JIG_HOME: repoRoot, ...env }),
  });
}

/**
 * What bash's `jig_task_state_var` answers for each key of task `id` in the project `cwd`:
 * `undefined` when the key has no line.
 */
export function bashStateValues(cwd: string, id: string, keys: readonly string[]): Map<string, string | undefined> {
  const r = bashLib(
    cwd,
    `jig_require_repo
id=$1; shift
for key in "$@"; do
  jig_task_state_var v "$id" "$key"
  printf '%s\\0%s\\0' "$_JIG_TS_FOUND" "$v"
done`,
    [id, ...keys],
  );
  if (r.code !== 0) throw new Error(`bash state read failed: ${r.stderr}`);
  const parts = r.stdout.split("\0");
  const out = new Map<string, string | undefined>();
  keys.forEach((key, i) => out.set(key, parts[2 * i] === "1" ? parts[2 * i + 1] : undefined));
  return out;
}

/** What bash's `_cfg_read_v` answers for each key in one file: `undefined` when no line sets it. */
export function bashConfigValues(cwd: string, file: string, keys: readonly string[]): Map<string, string | undefined> {
  const r = bashLib(
    cwd,
    `file=$1; shift
for key in "$@"; do
  if _cfg_read_v v "$file" "$key"; then rc=1; else rc=0; fi
  printf '%s\\0%s\\0' "$rc" "$v"
done`,
    [file, ...keys],
  );
  if (r.code !== 0) throw new Error(`bash config read failed: ${r.stderr}`);
  const parts = r.stdout.split("\0");
  const out = new Map<string, string | undefined>();
  keys.forEach((key, i) => out.set(key, parts[2 * i] === "1" ? parts[2 * i + 1] : undefined));
  return out;
}

export interface BashFm {
  /** `fm_get`: empty for an absent key or a list. */
  scalar: string;
  /** `fm_list`: the items, one per line. */
  list: string[];
}

/** What bash's `fm_get` and `fm_list` answer for each key of each file (`file\0key` order). */
export function bashFrontmatter(files: ReadonlyArray<readonly [string, readonly string[]]>): Map<string, BashFm> {
  const spec = files.map(([f, keys]) => [f, ...keys].join("\t")).join("\n");
  const r = bashLib(
    repoRoot,
    `. "$JIG_LIB/frontmatter.sh"
while IFS=$'\\t' read -r -a parts; do
  file=\${parts[0]}
  block=$(fm_block "$file")
  for key in "\${parts[@]:1}"; do
    fm_get_block_v s "$block" "$key"
    fm_list_block_v l "$block" "$key"
    printf '%s\\0%s\\0%s\\0%s\\0' "$file" "$key" "$s" "$l"
  done
done <<< "$FM_SPEC"`,
    [],
    { FM_SPEC: spec },
  );
  if (r.code !== 0) throw new Error(`bash frontmatter read failed: ${r.stderr}`);
  const parts = r.stdout.split("\0");
  const out = new Map<string, BashFm>();
  for (let i = 0; i + 3 < parts.length; i += 4) {
    const l = parts[i + 3] as string;
    out.set(`${parts[i]}\t${parts[i + 1]}`, { scalar: parts[i + 2] as string, list: l === "" ? [] : l.split("\n") });
  }
  return out;
}
