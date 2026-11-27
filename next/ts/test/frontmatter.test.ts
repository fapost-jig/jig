import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { JigError } from "../src/core/errors.ts";
import { parseFrontmatter, readFrontmatter } from "../src/core/storage/frontmatter.ts";
import { repoRoot, tmpDir } from "./helpers.ts";

const DOC = `---
id: convention-x
type: convention
status: active
domains: [scripts, tests]
paths:
  - "scripts/**"
  - "tests/**"
reviewed_at: 2026-11-26
summary: "Text with a colon: inside."
count: 0123
flag: true
---
# Body
`;

test("frontmatter is real YAML read with the failsafe schema: every scalar a string", () => {
  const fm = parseFrontmatter(DOC);
  assert.ok(fm);
  assert.deepEqual(fm.data, {
    id: "convention-x",
    type: "convention",
    status: "active",
    domains: ["scripts", "tests"],
    paths: ["scripts/**", "tests/**"],
    reviewed_at: "2026-11-26",
    summary: "Text with a colon: inside.",
    count: "0123",
    flag: "true",
  });
  assert.equal(fm.bodyLine, 14);
});

test("a file with no frontmatter, or an unclosed one, has none", () => {
  assert.equal(parseFrontmatter("# just text\n"), undefined);
  assert.equal(parseFrontmatter("---\nid: x\nno end\n"), undefined);
});

test("a CRLF file reads the same as an LF one", () => {
  assert.deepEqual(parseFrontmatter(DOC.replaceAll("\n", "\r\n"))?.data, parseFrontmatter(DOC)?.data);
});

test("bad YAML is refused with the file and the line", () => {
  const bad = "---\nid: x\npaths: [a, b\nother: y\n---\nbody\n";
  assert.throws(
    () => parseFrontmatter(bad, "knowledge/x.md"),
    (e: unknown) => e instanceof JigError && /^knowledge\/x\.md:\d+: invalid frontmatter/.test(e.message),
  );
  assert.throws(() => parseFrontmatter("---\na: 1\na: 2\n---\n", "d.md"), /d\.md:\d+: invalid frontmatter/);
});

test("an empty frontmatter is an empty map", () => {
  assert.deepEqual(parseFrontmatter("---\n---\nbody")?.data, {});
});

test("this repository's own knowledge documents all read", () => {
  const dir = path.join(repoRoot, ".ai", "knowledge");
  let n = 0;
  const walk = (d: string) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith(".md")) {
        const fm = readFrontmatter(p);
        if (fm !== undefined) {
          assert.equal(typeof fm.data["id"], "string", p);
          n++;
        }
      }
    }
  };
  walk(dir);
  assert.ok(n > 5, `read ${n} documents`);
});

test("readFrontmatter of a missing file is undefined", (t) => {
  assert.equal(readFrontmatter(path.join(tmpDir(t), "nope.md")), undefined);
});
