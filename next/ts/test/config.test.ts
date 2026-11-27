import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { cfg, cfgList, layeredConfig, localConfigFile, projectConfigFile } from "../src/core/storage/config.ts";
import { readLocalKeyLists } from "../src/core/storage/framework.ts";
import { bashLib, makeProject, repoRoot, tmpDir } from "./helpers.ts";

const keys = readLocalKeyLists(path.join(repoRoot, "scripts", "lib", "config.sh"));

test("the key lists are read from scripts/lib/config.sh and are not empty", () => {
  assert.ok(keys.local.has("housekeeping.cadence"));
  assert.ok(keys.localOnly.has("agent.git"));
  assert.ok(keys.local.size > 10 && keys.localOnly.size > 10);
});

test("the key lists equal what bash itself holds", (t) => {
  const dir = tmpDir(t);
  const r = bashLib(dir, 'printf "%s\\n" "$JIG_CFG_LOCAL_KEYS"; printf "%s\\n" "$JIG_CFG_LOCAL_ONLY_KEYS"');
  assert.equal(r.code, 0, r.stderr);
  const [local, only] = r.stdout.split("\n").map((l) => l.split(/\s+/).filter((w) => w !== ""));
  assert.deepEqual([...keys.local], local);
  assert.deepEqual([...keys.localOnly], only);
});

function project(t: { after(fn: () => void): void }): string {
  return makeProject(tmpDir(t), "git.base_branch: main\nhousekeeping.cadence: 5   # project\nagent.git: merge\nbase: [a, b]\nblank:\n");
}

test("layers: the project file answers for every key; the local file only for local keys", (t) => {
  const root = project(t);
  fs.writeFileSync(localConfigFile({ root }), "housekeeping.cadence: 9\ngit.base_branch: elsewhere\n");
  assert.deepEqual(layeredConfig({ root }, keys, "housekeeping.cadence"), { value: "9", layer: "local" });
  assert.deepEqual(layeredConfig({ root }, keys, "git.base_branch"), { value: "main", layer: "project" }, "not a local key: the local value is ignored");
  assert.deepEqual(layeredConfig({ root }, keys, "nothing.here"), { value: "", layer: "" });
});

test("a local-only key never reads the project file, and an empty local value falls through", (t) => {
  const root = project(t);
  assert.equal(cfg({ root }, keys, "agent.git", "none"), "none");
  fs.writeFileSync(localConfigFile({ root }), "agent.git: pr\nhousekeeping.cadence:\n");
  assert.equal(cfg({ root }, keys, "agent.git", "none"), "pr");
  assert.equal(cfg({ root }, keys, "housekeeping.cadence"), "5", "empty falls through to the project's value");
});

test("cfg gives the default for an empty or missing value; cfgList splits an inline list", (t) => {
  const root = project(t);
  assert.equal(cfg({ root }, keys, "blank", "dflt"), "dflt");
  assert.equal(cfg({ root }, keys, "missing", "dflt"), "dflt");
  assert.deepEqual(cfgList({ root }, keys, "base"), ["a", "b"]);
  assert.deepEqual(cfgList({ root }, keys, "missing"), []);
  assert.equal(projectConfigFile({ root }), path.join(root, ".ai", "config.yaml"));
});

test("the layered answer equals bash's cfg for a spread of keys", (t) => {
  const root = project(t);
  fs.writeFileSync(localConfigFile({ root }), "housekeeping.cadence: 9\nagent.git: pr\ngit.base_branch: x\nrun.exec:\n");
  const all = ["housekeeping.cadence", "agent.git", "git.base_branch", "run.exec", "base", "blank", "missing", "autopilot.git"];
  const r = bashLib(
    root,
    `jig_require_repo
for key in "$@"; do cfg_v v "$key" "<default>"; printf '%s\\0' "$v"; done`,
    all,
  );
  assert.equal(r.code, 0, r.stderr);
  const bash = r.stdout.split("\0");
  all.forEach((key, i) => assert.equal(cfg({ root }, keys, key, "<default>"), bash[i], key));
});
