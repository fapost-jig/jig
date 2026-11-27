// The documents a task's `Linked:` lines reach in neighbouring repositories
// (adr-20261029-a-task-reads-a-neighbouring-repository-through-a-link): `_ctx_linked_rows`, `_ctx_linked_lines`,
// and the task-reference grammar they read (`jig_task_ref`, `jig_task_ref_dir`, `jig_task_links`). Read only.

import path from "node:path";
import type { JigCtx } from "../context.ts";
import { hashPaths } from "../git/hash.ts";
import { validTaskId } from "../storage/state-read.ts";
import { isDir, isFile, physicalDir, readText } from "../storage/files.ts";
import { taskDir } from "../storage/state-read.ts";
import { cloneRoot } from "../storage/revision.ts";
import { WORKSPACE_ARTIFACTS, pad10 } from "./stateless.ts";

/** One link's answer: the absolute path of a document it reaches, or `-` with why it reaches nothing. */
export interface LinkedRow {
  /** An absolute path, or `-`. */
  readonly path: string;
  readonly ref: string;
  /** Only for `-`. */
  readonly why: string;
}

/** `jig_task_links`: each whole line `Linked: <ref>`, trimmed, as written. */
export function taskLinks(taskMd: string): string[] {
  const out: string[] = [];
  for (const raw of taskMd.split("\n")) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    if (!/^Linked:[ \t\n\v\f\r]/.test(line)) continue;
    const v = line.replace(/^Linked:[ \t\n\v\f\r]+/, "").replace(/[ \t\n\v\f\r]+$/, "");
    if (v !== "") out.push(v);
  }
  return out;
}

export interface TaskRef {
  readonly repo: string;
  readonly kind: "task" | "spec";
  readonly id: string;
}

/** `jig_task_ref`: parse `<repo>#<task-id>` or `<repo>#spec/<spec-id>`; a string says what is wrong. */
export function parseTaskRef(ref: string): TaskRef | string {
  if ((ref.match(/#/g) ?? []).length > 1) return "more than one #";
  if (!ref.includes("#")) return "no # between the repository and the id";
  const hash = ref.indexOf("#");
  const repo = ref.slice(0, hash);
  let id = ref.slice(hash + 1);
  if (repo === "") return "no repository path before #";
  if (repo.startsWith("/") || repo.startsWith("~") || /^[A-Za-z]:/.test(repo)) return "the repository path must be relative to the clone's main checkout";
  if (/[ \t\n\v\f\r\\]/.test(repo)) return "the repository path may not hold whitespace or a backslash";
  let kind: "task" | "spec" = "task";
  if (id.startsWith("spec/")) {
    kind = "spec";
    id = id.slice("spec/".length);
  }
  if (!validTaskId(id)) return `not a valid ${kind} id: ${id}`;
  return { repo, kind, id };
}

/** `jig_task_ref_dir`: the directory holding the referenced task's workspace or spec, or why there is none. */
export function taskRefDir(ctx: JigCtx, ref: TaskRef): { dir: string } | { error: string } {
  const root = cloneRoot(ctx.root);
  const dir = `${root}/${ref.repo}`;
  const abs = isDir(dir) ? physicalDir(dir) : undefined;
  if (abs === undefined) return { error: `no repository at ${dir}` };
  if (ref.kind === "spec") {
    const d = `${abs}/.ai/specs/${ref.id}`;
    if (!isFile(`${d}/spec.md`) && !isFile(`${d}/roadmap.md`)) return { error: `no spec ${ref.id} in ${abs}` };
    return { dir: d };
  }
  const d = `${abs}/.ai/workspace/tasks/${ref.id}`;
  if (!isFile(`${d}/task.md`)) {
    return { error: `no task ${ref.id} in ${abs} (a task workspace exists only in the clone that filed it)` };
  }
  return { dir: d };
}

/** `_ctx_linked_rows`: one row per document that exists, and one per link that reaches nothing. */
export function linkedRows(ctx: JigCtx, id: string): LinkedRow[] {
  if (id === "") return [];
  const own = physicalDir(taskDir(ctx, id)) ?? "";
  const md = readText(path.join(taskDir(ctx, id), "task.md"));
  if (md === undefined || !isFile(path.join(taskDir(ctx, id), "task.md"))) return [];
  const rows: LinkedRow[] = [];
  for (const ref of taskLinks(md)) {
    const parsed = parseTaskRef(ref);
    if (typeof parsed === "string") {
      rows.push({ path: "-", ref, why: `malformed link: ${parsed}; the form is <repo>#<task-id> or <repo>#spec/<spec-id>` });
      continue;
    }
    const where = taskRefDir(ctx, parsed);
    if ("error" in where) {
      rows.push({ path: "-", ref, why: where.error });
      continue;
    }
    if (parsed.kind === "task" && own !== "" && physicalDir(where.dir) === own) {
      rows.push({ path: "-", ref, why: "this is the task itself" });
      continue;
    }
    const files = parsed.kind === "spec" ? ["spec.md", "roadmap.md"] : ["task.md", ...WORKSPACE_ARTIFACTS];
    for (const f of files) if (isFile(`${where.dir}/${f}`)) rows.push({ path: `${where.dir}/${f}`, ref, why: "" });
  }
  return rows;
}

/** `_ctx_linked_docs`: the linked documents that exist. */
export function linkedDocs(ctx: JigCtx, id: string): string[] {
  return linkedRows(ctx, id).filter((r) => r.path !== "-").map((r) => r.path);
}

/** The ledger's lines for the task (`<hash><TAB><path>`), or undefined when it has none. */
export function ledgerLines(ctx: JigCtx, id: string): string[] | undefined {
  const file = path.join(taskDir(ctx, id), "context");
  if (!isFile(file)) return undefined;
  const text = readText(file);
  if (text === undefined) return undefined;
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines;
}

/** `_ctx_linked_lines`: resolve's `linked:` lines. A document that differs from the ledger's hash says so. */
export async function linkedLines(ctx: JigCtx, task: string): Promise<string> {
  if (task === "") return "";
  const rows = linkedRows(ctx, task);
  if (rows.length === 0) return "";
  const ledger = ledgerLines(ctx, task);
  const changed = new Set<string>();
  if (ledger !== undefined) {
    const have = new Map<string, string>();
    for (const l of ledger) {
      const f = l.split("\t");
      if (f.length >= 2) have.set(f[1] as string, f[0] as string);
    }
    const docs = rows.filter((r) => r.path !== "-").map((r) => r.path);
    if (docs.length > 0) {
      for (const h of await hashPaths(ctx, docs)) {
        const was = have.get(h.path);
        if (was !== undefined && was !== h.hash) changed.add(h.path);
      }
    }
  }
  let out = "";
  for (const r of rows) {
    if (r.path === "-") out += `${pad10("linked:")} ${r.ref}  unreachable: ${r.why}\n`;
    else if (changed.has(r.path)) out += `${pad10("linked:")} ${r.path}  (${r.ref}; changed since acknowledged)\n`;
    else out += `${pad10("linked:")} ${r.path}  (${r.ref})\n`;
  }
  return out;
}
