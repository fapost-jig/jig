import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { drift, generate, schemasDir } from "../tools/gen-schemas.ts";
import { Config, Frontmatter, TASK_STATE_KEYS, TaskState } from "../src/schemas/index.ts";
import { repoRoot } from "./helpers.ts";

test("the task state keys are the table of schemas/state.md", () => {
  const md = fs.readFileSync(path.join(repoRoot, "schemas", "state.md"), "utf8");
  const table = md.slice(md.indexOf("| Key |"), md.indexOf("`jig task show` prints"));
  const keys: string[] = [];
  for (const row of table.split("\n")) {
    const m = /^\| ((?:`[a-z_]+`(?:, )?)+) \|/.exec(row);
    if (m?.[1] !== undefined) for (const k of m[1].matchAll(/`([a-z_]+)`/g)) keys.push(k[1] as string);
  }
  assert.deepEqual([...TASK_STATE_KEYS].sort(), keys.sort());
});

test("TaskState: strings only, task_id by its pattern, absent keys allowed", () => {
  assert.ok(TaskState.safeParse({}).success);
  assert.ok(TaskState.safeParse({ task_id: "a.b-1", status: "active" }).success);
  assert.ok(!TaskState.safeParse({ task_id: ".hidden" }).success);
  assert.ok(!TaskState.safeParse({ task_id: "-x" }).success);
  assert.ok(!TaskState.safeParse({ status: 1 }).success);
});

test("Config and Frontmatter shapes", () => {
  assert.ok(Config.safeParse({ "git.base_branch": "main" }).success);
  assert.ok(!Config.safeParse({ "git.base_branch": 1 }).success);
  assert.ok(!Config.safeParse({ "bad key": "x" }).success);
  assert.ok(Frontmatter.safeParse({ a: "x", b: ["y", "z"], c: { d: "e" } }).success);
  assert.ok(!Frontmatter.safeParse({ a: 1 }).success);
});

test("the committed JSON Schemas equal the ones the code generates", () => {
  assert.deepEqual(drift(), []);
  for (const [file, text] of Object.entries(generate())) {
    assert.equal(fs.readFileSync(path.join(schemasDir, file), "utf8"), text);
  }
});
