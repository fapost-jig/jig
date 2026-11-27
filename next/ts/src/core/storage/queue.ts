// The queue file, `<clone root>/.ai/runtime/queue`, as its readers outside `jig queue` see it.
//
// `jig queue` is the queue's writer; this module reads it (a file of another format version holds nothing this
// reader can read, `_jig_queue_readable`, and so does a missing one) and replaces it when a caller that took a
// pause request out of it has rendered the new text (queue/write.ts).

import fs from "node:fs";
import path from "node:path";
import type { Ctx } from "../context.ts";
import { makeDirs, writeViaTemp } from "./files.ts";
import { lines } from "./flat.ts";
import { cloneRoot } from "./revision.ts";

const FORMAT = "1";

export function queueFile(ctx: Pick<Ctx, "root">): string {
  return path.join(cloneRoot(ctx.root), ".ai", "runtime", "queue");
}

/** `_jig_queue_line_readable`: a `# jig queue <n>` header whose fourth word is not this reader's version is unreadable. */
function headerReadable(first: string): boolean {
  if (!first.startsWith("# jig queue ")) return true;
  const words = first.split(/[ \t]+/).filter((w) => w !== "");
  return words[3] === FORMAT;
}

/** The lines of the queue, or an empty list when there is no queue or it is of another format version. */
export function readQueueLines(ctx: Pick<Ctx, "root">): string[] {
  let text: string;
  try {
    text = fs.readFileSync(queueFile(ctx), "utf8");
  } catch {
    return [];
  }
  const all = lines(text);
  if (all.length > 0 && !headerReadable(all[0] as string)) return [];
  return all;
}

/** The queue file's text, or undefined when there is none. */
export function readQueueText(ctx: Pick<Ctx, "root">): string | undefined {
  try {
    return fs.readFileSync(queueFile(ctx), "utf8");
  } catch {
    return undefined;
  }
}

/** Replace the queue file through a temporary and a rename (the directory made first); false when it cannot be done. */
export function writeQueueText(ctx: Pick<Ctx, "root">, text: string): boolean {
  const file = queueFile(ctx);
  return makeDirs(path.dirname(file)) && writeViaTemp(file, text);
}
