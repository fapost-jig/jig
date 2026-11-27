// The one write of the queue `context` makes: taking a pause request out (`jig queue cancel <ref> pause`),
// as `jig queue` writes it: the file is rendered as `_queue_apply` renders it (header, items in queue order,
// dependencies, requests, then any line it does not know), and landed as `_queue_commit` lands it: the
// revision read before the queue is claimed (`revisionClaim`), the file replaced, the revision raised once more.

import type { Ctx } from "../context.ts";
import { byteCompare } from "../storage/bytes.ts";
import { readQueueText, writeQueueText } from "../storage/queue.ts";
import { revisionClaim, revisionDir, revisionBump } from "../storage/revision.ts";

/** `beforeClaim` is a seam for tests: it runs between the queue's reading and the revision's claim, where another write can land. */
type QueueCtx = Pick<Ctx, "root" | "clock"> & { readonly beforeQueueClaim?: (() => void) | undefined };

const FORMAT = "1";

function awkNumber(s: string): number {
  const m = /^[ \t]*[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/.exec(s);
  return m === null ? 0 : Number(m[0]);
}

interface Item {
  ref: string;
  level: string;
  pos: string;
  pri: string;
}

/** `before(a, b)` of `_queue_apply`: the top level first, then by level, position and reference. */
function compareItems(a: Item, b: Item): number {
  if (a.level !== b.level) {
    if (a.level === "-") return -1;
    if (b.level === "-") return 1;
    return byteCompare(a.level, b.level);
  }
  const pa = awkNumber(a.pos);
  const pb = awkNumber(b.pos);
  if (pa !== pb) return pa < pb ? -1 : 1;
  return byteCompare(a.ref, b.ref);
}

/** How one attempt to take the request out ended. `stale`: another write landed since the revision was read. */
export type CancelResult =
  | { readonly kind: "taken"; readonly at: string; readonly reason: string }
  | { readonly kind: "none" }
  | { readonly kind: "stale" }
  | { readonly kind: "failed"; readonly why: string };

/** The queue after the request of `ref` is taken out, or what is wrong. */
function render(text: string, ref: string): { out: string; at: string; reason: string } | "none" | "format" {
  const lines = text === "" ? [] : text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  const items: Item[] = [];
  const seenItems = new Set<string>();
  const deps: { sub: string; on: string; reason: string }[] = [];
  const seenDeps = new Set<string>();
  const requests: { sub: string; kind: string; at: string; reason: string }[] = [];
  const seenRequests = new Set<string>();
  const other: string[] = [];
  for (let n = 0; n < lines.length; n++) {
    const line = lines[n] as string;
    if (n === 0 && line.startsWith("# jig queue ")) {
      const words = line.split(/[ \t]+/).filter((w) => w !== "");
      if (words[3] !== FORMAT) return "format";
      continue;
    }
    if (line.startsWith("#") || /^[ \t]*$/.test(line)) continue;
    const f = line.split("\t");
    if (f[0] === "item" && f.length >= 5) {
      if (seenItems.has(f[1] as string)) continue;
      seenItems.add(f[1] as string);
      items.push({ ref: f[1] as string, level: f[2] as string, pos: f[3] as string, pri: f[4] as string });
    } else if (f[0] === "dep" && f.length >= 4) {
      const key = `${f[1] as string}\u0000${f[2] as string}`;
      if (seenDeps.has(key)) continue;
      seenDeps.add(key);
      deps.push({ sub: f[1] as string, on: f[2] as string, reason: f[3] as string });
    } else if (f[0] === "request" && f.length >= 4) {
      const key = `${f[1] as string}\u0000${f[2] as string}`;
      if (seenRequests.has(key)) continue;
      seenRequests.add(key);
      requests.push({ sub: f[1] as string, kind: f[2] as string, at: f[3] as string, reason: f[4] ?? "" });
    } else {
      other.push(line);
    }
  }
  const at = requests.findIndex((r) => r.sub === ref && r.kind === "pause");
  if (at < 0) return "none";
  const taken = requests.splice(at, 1)[0] as { at: string; reason: string };
  let out = `# jig queue ${FORMAT} — written by \`jig queue\` only; do not edit by hand\n`;
  for (const i of [...items].sort(compareItems)) out += `item\t${i.ref}\t${i.level}\t${awkNumber(i.pos).toFixed(0)}\t${i.pri}\n`;
  for (const d of [...deps].sort((a, b) => byteCompare(a.sub, b.sub) || byteCompare(a.on, b.on))) out += `dep\t${d.sub}\t${d.on}\t${d.reason}\n`;
  for (const r of [...requests].sort((a, b) => byteCompare(a.sub, b.sub) || byteCompare(a.kind, b.kind))) {
    out += `request\t${r.sub}\t${r.kind}\t${r.at}\t${r.reason}\n`;
  }
  for (const o of other) out += `${o}\n`;
  return { out, at: taken.at, reason: taken.reason };
}

/**
 * One `jig queue cancel task:<id> pause` against `expected`, the revision its caller read before the queue (as
 * `_queue_commit` takes it): the queue is rendered without the request; the revision above `expected` is claimed (a claim
 * that loses is `stale`, the queue untouched: the caller reads again); the file is replaced; the revision is raised once more.
 */
export function cancelPauseRequest(ctx: QueueCtx, id: string, expected: number): CancelResult {
  const text = readQueueText(ctx);
  if (text === undefined) return { kind: "none" };
  const rendered = render(text, `task:${id}`);
  if (rendered === "none") return { kind: "none" };
  if (rendered === "format") return { kind: "failed", why: "queue: the queue is in another format than this jig writes (1); upgrade jig" };
  ctx.beforeQueueClaim?.();
  switch (revisionClaim(ctx.root, ctx.clock, expected)) {
    case "stale":
      return { kind: "stale" };
    case "unwritable":
      return { kind: "failed", why: `queue: cannot claim the clone revision in ${revisionDir(ctx.root)}` };
    case "claimed":
      break;
  }
  if (!writeQueueText(ctx, rendered.out)) return { kind: "failed", why: "queue: cannot write the queue file" };
  revisionBump(ctx.root, ctx.clock);
  return { kind: "taken", at: rendered.at, reason: rendered.reason };
}
