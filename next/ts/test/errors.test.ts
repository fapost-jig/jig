import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { asFailureCode, die, FAILURE_CODES, JigError } from "../src/core/errors.ts";
import { JsonEnvelope } from "../src/schemas/index.ts";
import { repoRoot } from "./helpers.ts";

test("the failure codes are the table of schemas/json.md, in its order", () => {
  const md = fs.readFileSync(path.join(repoRoot, "schemas", "json.md"), "utf8");
  const section = md.slice(md.indexOf("## Failure codes"), md.indexOf("## The revision"));
  const codes = [...section.matchAll(/^\| `([a-z]+(?:-[a-z]+)*)` \|/gm)].map((m) => m[1]).filter((c) => c !== "code");
  assert.deepEqual([...FAILURE_CODES], codes);
});

test("a code nobody knows reads failed", () => {
  assert.equal(asFailureCode("not-found"), "not-found");
  assert.equal(asFailureCode("brand-new-code"), "failed");
});

test("die is a refusal with no code of its own", () => {
  const e = die("nope");
  assert.ok(e instanceof JigError && e instanceof Error);
  assert.equal(e.code, "failed");
  assert.equal(e.message, "nope");
});

test("the envelope accepts data and error, one of them, and refuses the rest", () => {
  const base = { schema: 1, revision: 0, generated_at: "2026-09-21T13:33:20Z" };
  assert.ok(JsonEnvelope.safeParse({ ...base, data: { tasks: [] } }).success);
  assert.ok(JsonEnvelope.safeParse({ ...base, error: { code: "usage", message: "bad" } }).success);
  assert.ok(JsonEnvelope.safeParse({ ...base, error: { code: "made-up-yet", message: "x" } }).success, "unknown codes are allowed");
  assert.ok(!JsonEnvelope.safeParse(base).success, "neither data nor error");
  assert.ok(!JsonEnvelope.safeParse({ ...base, schema: 2, data: {} }).success);
  assert.ok(!JsonEnvelope.safeParse({ ...base, generated_at: "yesterday", data: {} }).success);
  assert.ok(!JsonEnvelope.safeParse({ ...base, error: { code: "Not A Code", message: "x" } }).success);
});
