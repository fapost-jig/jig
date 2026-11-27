// Absolute paths of linked documents as Node spells them on Windows (`C:\...`, `C:/...`): bash under Git Bash
// sees `/c/...` and tests a leading `/`; the port must take a drive letter for absolute too, or a task whose
// `Linked:` line reaches a document hashes it from the project root and guard/pending die.

import assert from "node:assert/strict";
import { test } from "node:test";
import type { ExecFn } from "../src/core/exec.ts";
import { hashPaths, isAbsolutePath } from "../src/core/git/hash.ts";

test("a path is absolute with a leading slash or a drive letter and a separator", () => {
  assert.equal(isAbsolutePath("/c/Users/x/task.md"), true);
  assert.equal(isAbsolutePath("C:\\Users\\x\\task.md"), true);
  assert.equal(isAbsolutePath("C:/Users/x/task.md"), true);
  assert.equal(isAbsolutePath(".ai/knowledge/a.md"), false);
  assert.equal(isAbsolutePath("C:relative"), false);
});

test("linked documents with a Windows drive letter are hashed in their own directory, by bare name", async () => {
  const calls: { dir: string; input: string }[] = [];
  const exec: ExecFn = async (_cmd, args, opts) => {
    const dir = args[args.indexOf("-C") + 1] ?? "";
    if (args.includes("--absolute-git-dir")) return { code: 0, stdout: Buffer.from("/repo/.git\n"), stderr: Buffer.alloc(0) };
    const input = String(opts?.input ?? "");
    calls.push({ dir, input });
    const n = input.split("\n").filter((l) => l !== "").length;
    return { code: 0, stdout: Buffer.from(`${Array.from({ length: n }, (_, i) => `h${dir.length}${i}`).join("\n")}\n`), stderr: Buffer.alloc(0) };
  };
  const out = await hashPaths({ root: "/repo", exec }, [
    ".ai/knowledge/a.md",
    "C:\\Users\\o\\other\\.ai\\workspace\\tasks\\t2/task.md",
    "C:\\Users\\o\\other\\.ai\\workspace\\tasks\\t2/plan.md",
    "D:\\spec\\roadmap.md",
  ]);
  assert.deepEqual(
    calls.map((c) => [c.dir, c.input]),
    [
      ["/repo", ".ai/knowledge/a.md\n"],
      ["C:\\Users\\o\\other\\.ai\\workspace\\tasks\\t2", "task.md\nplan.md\n"],
      ["D:\\spec", "roadmap.md\n"],
    ],
  );
  assert.deepEqual(
    out.map((h) => h.path),
    [".ai/knowledge/a.md", "C:\\Users\\o\\other\\.ai\\workspace\\tasks\\t2/task.md", "C:\\Users\\o\\other\\.ai\\workspace\\tasks\\t2/plan.md", "D:\\spec\\roadmap.md"],
  );
});
