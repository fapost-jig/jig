// A document the YAML reader refuses is read as bash reads it, never refused (a port reads any file 0.51.2 reads, exactly
// as 0.51.2 does). Each case is one the frontmatter reader's own tests list as refused (fixtures/frontmatter-differences.md);
// the last test runs bash's `jig context` on the same project and compares the answers. The process runner is a fake, except
// in that last test, which runs the real git beside bash.

import assert from "node:assert/strict";
import { test } from "node:test";
import { getList, getScalar, scanBlock } from "../src/core/storage/frontmatter-bash.ts";
import { jigContext, knowledgeProject, write } from "./context-helpers.ts";
import { bashJig } from "./helpers.ts";

const CASES: ReadonlyArray<readonly [string, string, string]> = [
  ["a colon in a plain scalar", "id: c\nstatus: active\nsummary: Text with: a colon\npaths:\n  - x\n", "paths: x"],
  ["a duplicate key", "id: first\nid: second\nstatus: active\npaths: [x]\n", "paths: x"],
  ["an unclosed inline list", "id: u\nstatus: active\npaths: [y, z\ndomains: [d]\n", "domains: d"],
  ["a non-map value", "- id\n- status\n", ""],
];

test("the bash reader's pieces: block, scalar, list", () => {
  const text = "---\nid: a # c\nstatus: \"active\"\nflag: [x\npaths: [a, \"b\", , c#d]\ndomains:\n  - p # n\n  - \"q\"\nother: 1\n\n\n---\nbody\n";
  const s = scanBlock(text);
  assert.ok(s?.closed);
  assert.equal(getScalar(s.block, "id"), "a");
  assert.equal(getScalar(s.block, "status"), "active");
  assert.equal(getScalar(s.block, "paths"), "");
  assert.deepEqual(getList(s.block, "paths"), ["a", "b", "c#d"]);
  assert.deepEqual(getList(s.block, "domains"), ["p", "q"]);
  assert.equal(scanBlock("---\nid: a\n")?.closed, false);
  assert.equal(scanBlock("id: a\n"), undefined);
});

for (const [name, front, expect] of CASES) {
  test(`context answers for a document with ${name}, as bash does`, async (t) => {
    const dir = knowledgeProject(t);
    write(dir, ".ai/knowledge/features/doc.md", `---\n${front}---\n# body\n`);
    const r = await jigContext(dir, ["--files", "x", "--domains", "d", "--all"]);
    assert.equal(r.code, 0, r.err);
    if (expect === "") assert.doesNotMatch(r.out, /matched/);
    else assert.match(r.out, new RegExp(`matched: {3}\\.ai/knowledge/features/doc\\.md {2}\\(${expect}\\)`));
    const resolved = await jigContext(dir, ["resolve", "--no-task", "--files", "x", "--domains", "d", "--all"]);
    assert.equal(resolved.code, 0, resolved.err);
  });
}

test("the answers equal bash's on documents the YAML reader refuses (real git, next to bash `jig context`)", async (t) => {
  const dir = knowledgeProject(t, undefined, true);
  for (const [i, [, front]] of CASES.entries()) write(dir, `.ai/knowledge/features/d${i}.md`, `---\n${front}---\n# body\n`);
  write(dir, ".ai/knowledge/features/ok.md", "---\nid: ok\nstatus: active\npaths:\n  - x\n---\n");
  const args = ["--files", "x,y", "--domains", "d", "--all"];
  const port = await jigContext(dir, args);
  const bash = bashJig(dir, ["context", ...args]);
  assert.equal(bash.code, 0, bash.stderr);
  assert.equal(port.out, bash.stdout);
  const resolveArgs = ["resolve", "--no-task", ...args, "--catalog"];
  assert.equal((await jigContext(dir, resolveArgs)).out, bashJig(dir, ["context", ...resolveArgs]).stdout);
});
