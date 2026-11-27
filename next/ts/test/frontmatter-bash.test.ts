// The YAML-based frontmatter reader against bash's fm_get / fm_list (scripts/lib/frontmatter.sh).
// The differences that are meant are listed in fixtures/frontmatter-differences.md; this test holds
// that list to what both readers really answer, and holds every knowledge document of this repository
// to "TypeScript equals bash".

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { JigError } from "../src/core/errors.ts";
import { parseFrontmatter } from "../src/core/storage/frontmatter.ts";
import { bashFrontmatter, repoRoot, tmpDir } from "./helpers.ts";
import type { BashFm } from "./helpers.ts";

type Answer = { kind: "scalar"; value: string } | { kind: "list"; items: string[] } | { kind: "error" };

/** What the TypeScript reader says for a key, in bash's terms: a scalar (empty for a list) and a list (empty for a scalar). */
function tsAnswer(text: string, key: string): Answer {
  let fm;
  try {
    fm = parseFrontmatter(text);
  } catch (e) {
    if (e instanceof JigError) return { kind: "error" };
    throw e;
  }
  const v = fm?.data[key];
  if (Array.isArray(v)) return { kind: "list", items: v.filter((x): x is string => typeof x === "string") };
  return { kind: "scalar", value: typeof v === "string" ? v : "" };
}

function same(ts: Answer, sh: BashFm): boolean {
  if (ts.kind === "error") return false;
  if (ts.kind === "list") return sh.scalar === "" && JSON.stringify(ts.items) === JSON.stringify(sh.list);
  return ts.value === sh.scalar && sh.list.length === 0;
}

function describe(a: Answer | BashFm): string {
  if ("kind" in a) return a.kind === "error" ? "error" : a.kind === "list" ? `list ${JSON.stringify(a.items)}` : `scalar ${JSON.stringify(a.value)}`;
  return a.list.length > 0 ? `list ${JSON.stringify(a.list)}` : `scalar ${JSON.stringify(a.scalar)}`;
}

interface Case {
  id: string;
  body: string; // the lines between the --- delimiters
  key: string;
  bash: string;
  ts: string;
}

const CASES: Case[] = [
  { id: "hash-in-quotes", body: 'summary: "a # b"', key: "summary", bash: 'scalar "\\"a"', ts: 'scalar "a # b"' },
  { id: "colon-in-plain-scalar", body: "summary: Text with: a colon", key: "summary", bash: 'scalar "Text with: a colon"', ts: "error" },
  { id: "single-quotes", body: "summary: 'quoted'", key: "summary", bash: "scalar \"'quoted'\"", ts: 'scalar "quoted"' },
  { id: "duplicate-key", body: "id: first\nid: second", key: "id", bash: 'scalar "first"', ts: "error" },
  { id: "comma-in-quoted-inline-item", body: 'paths: ["a,b", c]', key: "paths", bash: 'list ["\\"a","b\\"","c"]', ts: 'list ["a,b","c"]' },
  { id: "unclosed-inline-list", body: "paths: [a, b", key: "paths", bash: 'scalar ""', ts: "error" },
  { id: "unindented-block-list", body: "paths:\n- a\n- b", key: "paths", bash: 'scalar ""', ts: 'list ["a","b"]' },
  { id: "four-space-block-list", body: "paths:\n    - a\n    - b", key: "paths", bash: 'scalar ""', ts: 'list ["a","b"]' },
  { id: "hash-in-inline-item", body: "paths: [a#b, c]", key: "paths", bash: 'list ["a#b","c"]', ts: 'list ["a#b","c"]' },
];

/** Both readers on one body; returns [bash, ts] descriptions. */
function runCase(dir: string, c: Case): [string, string] {
  const text = `---\n${c.body}\n---\nbody\n`;
  const file = path.join(dir, `${c.id}.md`);
  fs.writeFileSync(file, text);
  const sh = bashFrontmatter([[file, [c.key]]]).get(`${file}\t${c.key}`) as BashFm;
  return [describe(sh), describe(tsAnswer(text, c.key))];
}

test("every listed difference is real, and says what both readers answer", (t) => {
  const dir = tmpDir(t);
  const doc = fs.readFileSync(path.join(import.meta.dirname, "fixtures", "frontmatter-differences.md"), "utf8");
  for (const c of CASES) {
    const [sh, ts] = runCase(dir, c);
    assert.equal(sh, c.bash, `${c.id}: bash`);
    assert.equal(ts, c.ts, `${c.id}: TypeScript`);
    assert.ok(doc.includes(`### ${c.id}`), `${c.id} is described in frontmatter-differences.md`);
  }
});

test("on this repository's knowledge documents TypeScript reads every key as bash does", () => {
  const root = path.join(repoRoot, ".ai", "knowledge");
  const files: string[] = [];
  const walk = (d: string): void => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".md")) files.push(p);
    }
  };
  walk(root);
  const work: Array<[string, string[]]> = [];
  const texts = new Map<string, string>();
  for (const f of files) {
    const text = fs.readFileSync(f, "utf8");
    const fm = parseFrontmatter(text, f);
    if (fm === undefined) continue;
    texts.set(f, text);
    work.push([f, [...Object.keys(fm.data), "no_such_key"]]);
  }
  assert.ok(work.length > 5);
  const bash = bashFrontmatter(work);
  const bad: string[] = [];
  let compared = 0;
  for (const [f, keys] of work) {
    for (const key of keys) {
      const sh = bash.get(`${f}\t${key}`) as BashFm;
      const ts = tsAnswer(texts.get(f) as string, key);
      compared++;
      if (!same(ts, sh)) bad.push(`${path.relative(repoRoot, f)}: ${key}: bash ${describe(sh)}, TypeScript ${describe(ts)}`);
    }
  }
  assert.ok(compared > 50, `compared ${compared}`);
  assert.deepEqual(bad, []);
});
