import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fixedClock } from "../src/core/clock.ts";
import { JigError } from "../src/core/errors.ts";
import { exec } from "../src/core/exec.ts";
import { createTaskState, readStateValue, readTaskState, setStateLine, stateFile, validTaskId, writeTaskState } from "../src/core/storage/state.ts";
import type { Ctx } from "../src/core/context.ts";
import { tmpDir } from "./helpers.ts";

function ctx(root: string): Ctx {
  return { root, exec, clock: fixedClock(1790000000), env: {} };
}

const SEED = [
  ["task_id", "demo"],
  ["status", "active"],
  ["knowledge_consolidated", "false"],
  ["created_at", "2026-09-21"],
  ["updated_at", "2026-09-21"],
] as const;

test("ids are validated like jig_valid_id", () => {
  for (const ok of ["a", "T-1", "a.b_c", "SRD-2455", "_x"]) assert.ok(validTaskId(ok), ok);
  for (const bad of ["", ".", "..", ".hidden", "-x", "a/b", "a b", "a\nb", "é"]) assert.ok(!validTaskId(bad), JSON.stringify(bad));
});

test("a task state is created in the order given, read back, and refused when it exists", (t) => {
  const root = tmpDir(t);
  createTaskState(ctx(root), "demo", SEED);
  assert.equal(
    fs.readFileSync(stateFile(ctx(root), "demo"), "utf8"),
    "task_id: demo\nstatus: active\nknowledge_consolidated: false\ncreated_at: 2026-09-21\nupdated_at: 2026-09-21\n",
  );
  assert.deepEqual(readTaskState(ctx(root), "demo"), {
    task_id: "demo",
    status: "active",
    knowledge_consolidated: "false",
    created_at: "2026-09-21",
    updated_at: "2026-09-21",
  });
  assert.throws(() => createTaskState(ctx(root), "demo", SEED), (e: unknown) => e instanceof JigError && e.code === "already-exists");
  assert.equal(readTaskState(ctx(root), "nobody"), undefined);
  assert.equal(readStateValue(ctx(root), "demo", "status"), "active");
  assert.equal(readStateValue(ctx(root), "demo", "domains"), undefined);
  assert.equal(readStateValue(ctx(root), "../etc", "status"), undefined);
});

test("a new key goes before created_at, an existing one is rewritten in place, updated_at is refreshed", (t) => {
  const root = tmpDir(t);
  createTaskState(ctx(root), "demo", SEED);
  writeTaskState(ctx(root), "demo", { domains: "a,b" });
  const day = new Date(1790000000 * 1000);
  const local = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, "0")}-${String(day.getDate()).padStart(2, "0")}`;
  assert.equal(
    fs.readFileSync(stateFile(ctx(root), "demo"), "utf8"),
    `task_id: demo\nstatus: active\nknowledge_consolidated: false\ndomains: a,b\ncreated_at: 2026-09-21\nupdated_at: ${local}\n`,
  );
  writeTaskState(ctx(root), "demo", { status: "ready", domains: "c" });
  assert.equal(
    fs.readFileSync(stateFile(ctx(root), "demo"), "utf8"),
    `task_id: demo\nstatus: ready\nknowledge_consolidated: false\ndomains: c\ncreated_at: 2026-09-21\nupdated_at: ${local}\n`,
  );
});

test("a key is appended when there is no created_at, and every line of a repeated key is rewritten", () => {
  assert.equal(setStateLine("task_id: x\n", "status", "active", "D"), "task_id: x\nstatus: active\n");
  assert.equal(setStateLine("a: 1\nstatus: x\nstatus: y\n", "status", "z", "D"), "a: 1\nstatus: z\nstatus: z\n");
  assert.equal(setStateLine("a: 1\nupdated_at: old", "a", "2", "D"), "a: 2\nupdated_at: D\n");
});

test("what is not a key of the schema, or not a value bash reads back as written, is refused and nothing is written", (t) => {
  const root = tmpDir(t);
  createTaskState(ctx(root), "demo", SEED);
  const before = fs.readFileSync(stateFile(ctx(root), "demo"), "utf8");
  const refuse = (updates: Record<string, string>, code: string) =>
    assert.throws(
      () => writeTaskState(ctx(root), "demo", updates),
      (e: unknown) => e instanceof JigError && e.code === code,
      JSON.stringify(updates),
    );
  refuse({ no_such_key: "x" }, "unknown-key");
  refuse({ status: "a\nb" }, "invalid-value");
  refuse({ status: "a\rb" }, "invalid-value");
  refuse({ status: " leading" }, "invalid-value");
  refuse({ status: "\tleading" }, "invalid-value");
  refuse({ task_id: "not valid" }, "invalid-value");
  refuse({ domains: "ok", status: "bad\n" }, "invalid-value");
  assert.equal(fs.readFileSync(stateFile(ctx(root), "demo"), "utf8"), before);
  assert.throws(() => writeTaskState(ctx(root), "ghost", { status: "x" }), (e: unknown) => e instanceof JigError && e.code === "not-found");
  assert.throws(() => writeTaskState(ctx(root), "../x", { status: "x" }), (e: unknown) => e instanceof JigError && e.code === "usage");
});

test("a write leaves no temporary file behind", (t) => {
  const root = tmpDir(t);
  createTaskState(ctx(root), "demo", SEED);
  writeTaskState(ctx(root), "demo", { status: "ready" });
  assert.deepEqual(fs.readdirSync(path.dirname(stateFile(ctx(root), "demo"))), ["state"]);
});

test("reading takes the first line of a key, ignores unknown keys and refuses an invalid task_id", (t) => {
  const root = tmpDir(t);
  const dir = path.join(root, ".ai", "workspace", "tasks", "demo");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "state"), "task_id: demo\nfuture_key: x\nstatus: a\nstatus: b\nnot a key line\n1bad: x\n");
  assert.deepEqual(readTaskState(ctx(root), "demo"), { task_id: "demo", status: "a" });
  fs.writeFileSync(path.join(dir, "state"), "task_id: .bad\n");
  assert.throws(() => readTaskState(ctx(root), "demo"), (e: unknown) => e instanceof JigError && /task_id/.test(e.message));
});
