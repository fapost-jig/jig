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
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
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

/**
 * The bash `jig`, run from the framework checkout this test lives in, against the project `cwd`. It stays on the checkout:
 * it tests the command surface (the epic's JIG_NOW refusal, which 0.51.2 lacks), not the storage readers and writers.
 */
export function bashJig(cwd: string, args: readonly string[], env: Record<string, string> = {}): Proc {
  return proc("bash", [jigBin, ...args], { cwd, env: cleanEnv({ HOME: cwd, ...env }) });
}

/**
 * The rollback baseline of the rewrite (adr-20261126-jig-1-0-is-rewritten-off-bash-and-the-pilot-picks-the-language):
 * the bash the storage readers and writers are checked against is `scripts/lib` at this tag, not the checkout, which is an
 * epic branch that keeps changing bash.
 */
const BASELINE_TAG = "v0.51.2";

let baselineDir: string | undefined;

/** The clock section of common.sh: from its heading to `jig_today`, its last line. */
function clockSection(common: string): string {
  const lines = common.split("\n");
  const from = lines.findIndex((l) => l.startsWith("# --- the clock ---"));
  const to = lines.findIndex((l, i) => i >= from && l.startsWith("jig_today() {"));
  if (from < 0 || to < 0) throw new Error("the clock section is not in scripts/lib/common.sh");
  return `${lines.slice(from, to + 1).join("\n")}\n`;
}

/**
 * `scripts/lib` as at the baseline tag plus `clock.sh`, this checkout's clock section, extracted once per process into a
 * temporary directory that goes with the process. Files come from `git cat-file`, the committed bytes whatever autocrlf says.
 */
export function baselineLib(): string {
  if (baselineDir !== undefined) return baselineDir;
  const git = (...args: string[]): Buffer => {
    const r = spawnSync("git", ["-C", repoRoot, ...args], { maxBuffer: 64 * 1024 * 1024 });
    if (r.error || r.status !== 0) {
      throw new Error(
        `the bash oracle needs the rollback baseline tag ${BASELINE_TAG}: run \`git fetch origin tag ${BASELINE_TAG}\` (git ${args.join(" ")}: ${r.error?.message ?? r.stderr.toString().trim()})`,
      );
    }
    return r.stdout;
  };
  const files = git("ls-tree", "--name-only", BASELINE_TAG, "scripts/lib/").toString("utf8").split("\n").filter((f) => f !== "");
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), "jig-oracle-baseline-")));
  process.on("exit", () => fs.rmSync(dir, { recursive: true, force: true }));
  for (const f of files) fs.writeFileSync(path.join(dir, path.basename(f)), git("cat-file", "blob", `${BASELINE_TAG}:${f}`));
  fs.writeFileSync(path.join(dir, "clock.sh"), clockSection(fs.readFileSync(path.join(repoRoot, "scripts", "lib", "common.sh"), "utf8")));
  baselineDir = dir;
  return dir;
}

// The baseline reads the clock through `date` and knows nothing of JIG_NOW; the checkout's clock section (clock.sh) is the
// clock seam, and the `date` function lays it over the baseline: with JIG_NOW set, a `date` that reads "now" answers the
// pinned instant. Pinning is blanket: it also pins the few reads the baseline makes for waits and mtimes, which these
// tests do not call. The pinned form of jig_now_date runs `date -d @N` / `date -r N`, which carry -d / -r and so go to the
// real `date` (no recursion).
const FRAMEWORK = `
set -eu
export JIG_LIB
. "$JIG_LIB/version.sh"
. "$JIG_LIB/common.sh"
. "$JIG_LIB/config.sh"
. "$JIG_LIB/clock.sh"
date() {
  local a
  if [ -n "\${JIG_NOW:-}" ]; then
    for a in "$@"; do
      case "$a" in
        -d* | -r* | -j | -f*) command date "$@"; return ;;
      esac
    done
    jig_now_date "$@"
    return
  fi
  command date "$@"
}
`;

/**
 * Runs a bash body with the baseline's libraries sourced and the epic's clock laid over them; $JIG_HOME is this checkout,
 * $JIG_LIB the baseline.
 */
export function bashLib(cwd: string, body: string, args: readonly string[] = [], env: Record<string, string> = {}): Proc {
  return proc("bash", ["-c", `${FRAMEWORK}\n${body}`, "bash", ...args], {
    cwd,
    env: cleanEnv({ HOME: cwd, JIG_HOME: repoRoot, JIG_LIB: baselineLib().replaceAll("\\", "/"), ...env }),
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
