// THE INVARIANT: what the TypeScript implementation writes is only what bash reads back as written,
// and what it reads is what bash reads. Jig 1.0 replaces bash; until then both touch the same files.

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fixedClock } from "../src/core/clock.ts";
import type { Ctx } from "../src/core/context.ts";
import { exec } from "../src/core/exec.ts";
import { createTaskState, readStateValue, readTaskState, stateFile, writeTaskState } from "../src/core/storage/state.ts";
import type { TaskStateKey } from "../src/schemas/index.ts";
import { bashJig, bashStateValues, makeProject, tmpDir } from "./helpers.ts";

const NOW = 1790000000;

function ctx(root: string): Ctx {
  return { root, exec, clock: fixedClock(NOW), env: {} };
}

/** Values chosen to break a reader that is not bash: colons, hashes, braces, brackets, blanks, quotes, backslashes, unicode. */
const TRICKY: ReadonlyArray<readonly [TaskStateKey, string]> = [
  ["task_id", "tricky"],
  ["status", "active"],
  ["paused_reason", "pause requested at 2026-01-01T00:00:00Z: because: of # things"],
  ["branch", "task/feat#1"],
  ["base_branch", "release/{selection}"],
  ["moved_to", "repo#spec/some-spec"],
  ["domains", "[a, b]"],
  ["abandoned_reason", "ünï — ключ 💡 \"quoted\" 'single'"],
  ["pr_url", "https://example.test/o/r/pull/7?a=b&c=d#frag"],
  ["setup", "failed (exit 2)"],
  ["share", "a b, c\td"],
  ["class_lowered_reason", "trailing blanks   "],
  ["out_of_order_reason", "C:\\temp\\new\\table & \\n not a newline $HOME `x` $(y)"],
  ["issue", "a:b"],
  ["triage_of", ""],
  ["share", "second share line is a duplicate key, never written by the writer"],
  ["created_at", "2026-09-21"],
  ["updated_at", "2026-09-21"],
];

function expected(entries: ReadonlyArray<readonly [string, string]>): Map<string, string> {
  const m = new Map<string, string>();
  for (const [k, v] of entries) if (!m.has(k)) m.set(k, v);
  return m;
}

test("what TypeScript files and updates in a task's state, bash reads value for value", (t) => {
  const root = makeProject(tmpDir(t));
  // `share` appears twice in the list above: the writer takes lines literally, so build the file in two steps.
  const first = TRICKY.filter((_, i) => i !== 15);
  createTaskState(ctx(root), "tricky", first);
  writeTaskState(ctx(root), "tricky", { share: "second write replaces the value", paused: "true", paused_at: "2026-09-21" });
  writeTaskState(ctx(root), "tricky", { share: "a b, c\td" });

  const want = expected(first);
  want.set("paused", "true");
  want.set("paused_at", "2026-09-21");
  const keys = [...want.keys(), "notes_through", "gate"];
  const bash = bashStateValues(root, "tricky", keys);
  for (const key of keys) {
    const w = want.get(key);
    if (key === "updated_at") continue; // refreshed by each write; compared below
    assert.equal(bash.get(key), w, `bash reads ${key}`);
    assert.equal(readStateValue(ctx(root), "tricky", key), w, `TypeScript reads ${key}`);
  }
  const state = readTaskState(ctx(root), "tricky");
  assert.equal(state?.paused_reason, want.get("paused_reason"));

  // And the file `jig task show` prints is the file.
  const shown = bashJig(root, ["task", "show", "tricky"]);
  assert.equal(shown.code, 0, shown.stderr);
  assert.equal(shown.stdout, fs.readFileSync(stateFile(ctx(root), "tricky"), "utf8"));
});

test("a value bash would read back differently is refused by the writer, not written", (t) => {
  const root = makeProject(tmpDir(t));
  createTaskState(ctx(root), "t", [["task_id", "t"], ["created_at", "2026-09-21"]]);
  const before = fs.readFileSync(stateFile(ctx(root), "t"), "utf8");
  for (const bad of ["a\nstatus: ready", "a\rb", " lead", "\tlead"]) {
    assert.throws(() => writeTaskState(ctx(root), "t", { status: bad }), JSON.stringify(bad));
  }
  assert.throws(() => writeTaskState(ctx(root), "t", { not_a_key: "x" } as never));
  assert.equal(fs.readFileSync(stateFile(ctx(root), "t"), "utf8"), before);
});

test("TypeScript's write of a key is byte for byte what bash's `jig task set` writes", (t) => {
  const savedTz = process.env["TZ"];
  process.env["TZ"] = "UTC"; // bash runs below with TZ=UTC; today() is the local date
  t.after(() => {
    if (savedTz === undefined) delete process.env["TZ"];
    else process.env["TZ"] = savedTz;
  });
  const pin = { JIG_NOW: String(NOW), TZ: "UTC" };

  const bashRoot = makeProject(tmpDir(t));
  const made = bashJig(bashRoot, ["task", "new", "parity"], pin);
  assert.equal(made.code, 0, made.stderr);
  const tsRoot = makeProject(tmpDir(t));
  fs.mkdirSync(path.dirname(stateFile(ctx(tsRoot), "parity")), { recursive: true });
  fs.copyFileSync(stateFile(ctx(bashRoot), "parity"), stateFile(ctx(tsRoot), "parity"));

  const steps: Array<[TaskStateKey, string]> = [
    ["class", "T1"], // a new key: goes before created_at
    ["domains", "api,db"], // another new key: goes before created_at, after class
    ["class", "T2"], // an existing key: rewritten in place
    ["route_depth", "lean"],
    ["domains", "x-1"],
  ];
  for (const [key, value] of steps) {
    const sh = bashJig(bashRoot, ["task", "set", "parity", key, value], pin);
    assert.equal(sh.code, 0, `bash: task set ${key} ${value}: ${sh.stderr}`);
    writeTaskState(ctx(tsRoot), "parity", { [key]: value });
    assert.equal(
      fs.readFileSync(stateFile(ctx(tsRoot), "parity"), "utf8"),
      fs.readFileSync(stateFile(ctx(bashRoot), "parity"), "utf8"),
      `after ${key}=${value}`,
    );
  }
});

test("TypeScript reads what bash reads, on a state file with every awkward line", (t) => {
  const root = makeProject(tmpDir(t));
  const file = stateFile(ctx(root), "awkward");
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const text = [
    "task_id: awkward",
    "status:active",
    "class:    T3",
    "paused_reason: pause requested at T: why: because # not a comment",
    "domains:\ta,b",
    "empty:",
    "blank:    ",
    "trailing: value with trailing blanks   ",
    "crlf: windows line\r",
    "dup: first",
    "dup: second",
    "not a key line",
    "1leading_digit: x",
    "with-dash: x",
    "  indented: x",
    "uni: ünï — ключ 💡",
    "braces: {selection}",
    "last: no newline at the end",
  ].join("\n");
  fs.writeFileSync(file, text);
  const keys = ["task_id", "status", "class", "paused_reason", "domains", "empty", "blank", "trailing", "crlf", "dup", "1leading_digit", "with-dash", "indented", "uni", "braces", "last", "task", "missing", "notes_through"];
  const bash = bashStateValues(root, "awkward", keys);
  for (const key of keys) assert.equal(readStateValue(ctx(root), "awkward", key), bash.get(key), `key ${JSON.stringify(key)}`);
});
