import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { configValue, inlineList, lines, stateValue } from "../src/core/storage/flat.ts";
import { bashConfigValues, bashLib, repoRoot, tmpDir } from "./helpers.ts";

test("lines reads as `while read` does: a last line without a newline counts, a final newline adds nothing", () => {
  assert.deepEqual(lines(""), []);
  assert.deepEqual(lines("a\nb"), ["a", "b"]);
  assert.deepEqual(lines("a\nb\n"), ["a", "b"]);
  assert.deepEqual(lines("a\n\nb\n"), ["a", "", "b"]);
});

test("configValue: the first line wins, the value stops at the first #, trailing blanks go", () => {
  const text = [
    "plain: value",
    "hashed: a # comment",
    "tight: x#y",
    "spaced:    padded   ",
    "empty:",
    "empty: later",
    "list: [a, b]  # trailing",
    "sel: {selection}",
    "colons: a: b: c",
    "quoted: \"q # not a comment\"",
    "uni: ünï — ключ 💡 # c",
    "tabs:\ttabbed\t\t",
    "crlf: windows\r",
    "dup: first",
    "dup: second",
  ].join("\n");
  assert.equal(configValue(text, "plain"), "value");
  assert.equal(configValue(text, "hashed"), "a");
  assert.equal(configValue(text, "tight"), "x");
  assert.equal(configValue(text, "spaced"), "padded");
  assert.equal(configValue(text, "empty"), "", "the first line of a key decides, even when empty");
  assert.equal(configValue(text, "list"), "[a, b]");
  assert.equal(configValue(text, "sel"), "{selection}");
  assert.equal(configValue(text, "colons"), "a: b: c");
  assert.equal(configValue(text, "quoted"), '"q');
  assert.equal(configValue(text, "uni"), "ünï — ключ 💡");
  assert.equal(configValue(text, "tabs"), "tabbed");
  assert.equal(configValue(text, "crlf"), "windows");
  assert.equal(configValue(text, "dup"), "first");
  assert.equal(configValue(text, "absent"), undefined);
});

test("configValue: the key is a pattern, so `.` stands for any character, and a prefix is not the key", () => {
  assert.equal(configValue("notify_telegram_token: tok\n", "notify.telegram.token"), "tok");
  assert.equal(configValue("axb: z\na.b: y\n", "a.b"), "z");
  assert.equal(configValue("agent.git_staging: x\n", "agent.git"), undefined);
  assert.equal(configValue("  indented: x\n", "indented"), undefined);
  assert.throws(() => configValue("", "a b"), /not a config key/);
});

test("inlineList is cfg_list_lines: brackets, commas, trimmed items, one pair of quotes, no empties", () => {
  assert.deepEqual(inlineList("[a, b]"), ["a", "b"]);
  assert.deepEqual(inlineList("[ a ,b,, c ]"), ["a", "b", "c"]);
  assert.deepEqual(inlineList('["scripts/**", "x y"]'), ["scripts/**", "x y"]);
  assert.deepEqual(inlineList("a, b"), ["a", "b"]);
  assert.deepEqual(inlineList("solo"), ["solo"]);
  assert.deepEqual(inlineList("[]"), []);
  assert.deepEqual(inlineList('[""]'), []);
  assert.deepEqual(inlineList('["]'), ['"']);
});

test("stateValue: everything after the colon, leading blanks gone, trailing kept, first line wins", () => {
  const text = [
    "task_id: demo",
    "paused_reason: pause requested at T: because: of # things",
    "pad:     leading",
    "trail: value  ",
    "empty:",
    "tab:\tx\ty",
    "crlf: x\r",
    "dup: 1",
    "dup: 2",
    "nospace:value",
    "uni: ünï — ключ",
  ].join("\n");
  assert.equal(stateValue(text, "task_id"), "demo");
  assert.equal(stateValue(text, "paused_reason"), "pause requested at T: because: of # things");
  assert.equal(stateValue(text, "pad"), "leading");
  assert.equal(stateValue(text, "trail"), "value  ");
  assert.equal(stateValue(text, "empty"), "");
  assert.equal(stateValue(text, "tab"), "x\ty");
  assert.equal(stateValue(text, "crlf"), "x\r");
  assert.equal(stateValue(text, "dup"), "1");
  assert.equal(stateValue(text, "nospace"), "value");
  assert.equal(stateValue(text, "uni"), "ünï — ключ");
  assert.equal(stateValue(text, "absent"), undefined);
  assert.equal(stateValue(text, "task"), undefined, "a prefix of a key is not the key");
  assert.equal(stateValue("last: no newline", "last"), "no newline");
});

const TRICKY_CONFIG = [
  "plain: value",
  "a.b: with comment # gone",
  "tight: x#y",
  "spaced:    padded   ",
  "empty:",
  "empty: later",
  "list: [a, b]  # trailing",
  "sel: {selection}",
  "colons: a: b: c",
  "quoted: \"q # not a comment\"",
  "uni: ünï — ключ 💡 # c",
  "tabs:\ttabbed\t\t",
  "crlf: windows\r",
  "dup: first",
  "dup: second",
  "notify_telegram_token: tok",
  "axb: wild",
  "hash-only: # nothing",
  "x: #",
  "last: no newline at the end",
].join("\n");

test("configValue reads every key as bash's _cfg_read_v does", (t) => {
  const dir = tmpDir(t);
  const file = path.join(dir, "config.yaml");
  fs.writeFileSync(file, TRICKY_CONFIG);
  const keys = [
    ...new Set([...TRICKY_CONFIG.matchAll(/^([A-Za-z0-9_.-]+):/gm)].map((m) => m[1] as string)),
    "notify.telegram.token",
    "a.b",
    "axb",
    "absent",
    "pla",
    "plain.x",
    "list",
  ];
  const bash = bashConfigValues(dir, file, keys);
  for (const key of keys) assert.equal(configValue(TRICKY_CONFIG, key), bash.get(key), `key ${key}`);
});

test("configValue reads this repository's real config and profiles as bash does", () => {
  const files = [path.join(repoRoot, ".ai", "config.yaml")];
  const profiles = path.join(repoRoot, "profiles");
  for (const name of fs.readdirSync(profiles)) {
    const f = path.join(profiles, name, "profile.yaml");
    if (fs.existsSync(f)) files.push(f);
  }
  assert.ok(files.length > 3, "found the profiles");
  let compared = 0;
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    const keys = [...new Set([...text.matchAll(/^([A-Za-z0-9_.-]+):/gm)].map((m) => m[1] as string)), "no.such.key"];
    const bash = bashConfigValues(repoRoot, file, keys);
    for (const key of keys) {
      assert.equal(configValue(text, key), bash.get(key), `${path.relative(repoRoot, file)}: ${key}`);
      compared++;
    }
  }
  assert.ok(compared > 20, `compared ${compared} keys`);
  // The key the design calls out: {selection} is text, not a mapping.
  const shell = fs.readFileSync(path.join(profiles, "shell", "profile.yaml"), "utf8");
  assert.equal(configValue(shell, "checks.tests.narrowed"), "{selection}");
});

test("inlineList agrees with bash's cfg_list_lines", (t) => {
  const dir = tmpDir(t);
  for (const raw of ["[a, b]", '["scripts/**", "x y", ""]', "a, b", "solo", "[ a ,b,, c ]", "[]", '["]', "[a]b]", "", '"a", "b"']) {
    // cfg_list_lines asks `cfg <key> ""`; here cfg answers with the text under test.
    const r = bashLib(dir, 'cfg() { printf "%s\\n" "$RAW"; }\ncfg_list_lines some.key', [], { RAW: raw });
    assert.equal(r.code, 0, r.stderr);
    const wanted = r.stdout === "" ? [] : r.stdout.replace(/\n$/, "").split("\n");
    assert.deepEqual(raw === "" ? [] : inlineList(raw), wanted, JSON.stringify(raw));
  }
});
