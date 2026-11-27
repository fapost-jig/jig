// The pure parts of `jig context`: glob matching, status, the queue's place and the age of a pause request.

import assert from "node:assert/strict";
import { test } from "node:test";
import { fixedClock } from "../src/core/clock.ts";
import { commaWords, globRegExp, pathMatchesAny, statusResolvable } from "../src/core/knowledge/match.ts";
import { pauseRequest, queuePlace, utcAgo } from "../src/core/queue/read.ts";
import { sortBytes } from "../src/core/storage/bytes.ts";

test("a double star matches any depth, and a single star crosses a slash too", () => {
  assert.ok(pathMatchesAny("src/Flow/**", ["src/Flow/A.php"]));
  assert.ok(pathMatchesAny("src/Flow/**", ["src/Flow/a/b/C.php"]));
  assert.ok(pathMatchesAny("**/*.sh", ["scripts/lib/x.sh"]));
  assert.ok(pathMatchesAny("**/*.sh", ["x.sh"]));
  assert.ok(pathMatchesAny("app/Services/Trigger*", ["app/Services/TriggerService.php"]));
  assert.ok(pathMatchesAny("app/Services/Trigger*", ["app/Services/Trigger/Nested.php"]));
  assert.ok(!pathMatchesAny("app/Services/Trigger*", ["app/Services/Other/TriggerService.php"]));
});

test("a glob ending in a slash covers the directory, and docs/** and docs/ both match a file directly under docs", () => {
  assert.ok(pathMatchesAny("src/Dir/", ["src/Dir/A.php"]));
  assert.ok(pathMatchesAny("docs/**/", ["docs/a.md"]));
  assert.ok(pathMatchesAny("docs/**", ["docs/a.md"]));
  assert.ok(!pathMatchesAny("src/Dir/", ["src/Other/A.php"]));
});

test("question marks, brackets and regular-expression characters stand for themselves", () => {
  assert.ok(pathMatchesAny("src/a?b[c].php", ["src/a?b[c].php"]));
  assert.ok(!pathMatchesAny("src/a?b[c].php", ["src/axbc.php"]));
  assert.ok(pathMatchesAny("a.b+c(d)|e^$", ["a.b+c(d)|e^$"]));
  assert.ok(!pathMatchesAny("a.b", ["axb"]));
  assert.ok(pathMatchesAny("a\\b", ["a\\b"]));
  assert.equal(globRegExp("x").test("x\n"), false);
});

test("empty lines in the file list match nothing, not even an empty glob prefix", () => {
  assert.ok(!pathMatchesAny("*", [""]));
  assert.ok(pathMatchesAny("*", ["", "a"]));
});

test("only active and accepted resolve", () => {
  assert.ok(statusResolvable("active"));
  assert.ok(statusResolvable("accepted"));
  for (const s of ["proposed", "superseded", "deprecated", "rejected", "typo", ""]) assert.ok(!statusResolvable(s));
});

test("a comma list is read as words, blanks and commas alike", () => {
  assert.deepEqual(commaWords("a, b,c  d"), ["a", "b", "c", "d"]);
  assert.deepEqual(commaWords(""), []);
});

test("sorting is by bytes: an upper-case name sorts before a lower-case one", () => {
  assert.deepEqual(sortBytes(["b", "B", "a", "_x"]), ["B", "_x", "a", "b"]);
});

const QUEUE = [
  "# jig queue 1",
  "item\ttask:a\tepic:big\t1\t-",
  "item\ttask:t1\tepic:big\t2\t0",
  "item\ttask:b\ttop\t1\t3",
  "dep\ttask:t1\ttask:a\tneeds a",
];

test("a task's place is its rank on its level, its priority and what it waits for", () => {
  const p = queuePlace(QUEUE, "t1");
  assert.deepEqual(p, { level: "epic:big", priority: "0", rank: 2, count: 2, deps: [{ on: "task:a", reason: "needs a" }] });
  assert.equal(queuePlace(QUEUE, "b")?.rank, 1);
  assert.equal(queuePlace(QUEUE, "zzz"), undefined);
});

test("a pause request is the first request line for the task", () => {
  const q = ["request\ttask:t1\tpause\t2026-01-01T00:00:00Z\tstandup\tignored", "request\ttask:t1\tpause\t2027-01-01T00:00:00Z\t"];
  assert.deepEqual(pauseRequest(q, "t1"), { at: "2026-01-01T00:00:00Z", reason: "standup" });
  assert.equal(pauseRequest(q, "t2"), undefined);
  assert.deepEqual(pauseRequest(["request\ttask:t\tpause\t2026-01-01T00:00:00Z"], "t"), { at: "2026-01-01T00:00:00Z", reason: "" });
});

test("the age of a time is told in words", () => {
  const at = "2026-01-01T00:00:00Z";
  const base = Date.UTC(2026, 0, 1) / 1000;
  const ago = (s: number): string => utcAgo(fixedClock(base + s), at);
  assert.equal(ago(59), "just now");
  assert.equal(ago(60), "1 min");
  assert.equal(ago(3599), "59 min");
  assert.equal(ago(3600), "1 h");
  assert.equal(ago(172799), "47 h");
  assert.equal(ago(172800), "2 days");
  assert.equal(utcAgo(fixedClock(base), "yesterday"), "");
});
