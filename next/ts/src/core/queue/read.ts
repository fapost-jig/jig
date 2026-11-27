// A task's place in the queue and a pause asked of it, read as `jig status` and `jig context` read them
// (`jig_queue_place`, `jig_pause_request`, `jig_utc_ago`). Reading only.

import type { Clock } from "../clock.ts";

export interface Dependency {
  readonly on: string;
  readonly reason: string;
}

export interface QueuePlace {
  /** `-` for the top level, else `epic:<spec>`. */
  readonly level: string;
  /** `-` for none, else as stored. */
  readonly priority: string;
  readonly rank: number;
  readonly count: number;
  readonly deps: readonly Dependency[];
}

/** awk's `$n + 0`: the leading number of the text, or 0. */
function awkNumber(s: string): number {
  const m = /^[ \t]*[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/.exec(s);
  return m === null ? 0 : Number(m[0]);
}

/**
 * `jig_queue_place`: the place of task `id` among the queue's `item` lines, or undefined when it is not
 * queued. The queue's position is compared within its level only. Of two items for one task the last
 * one decides, and the dependencies of both are kept, as bash does.
 */
export function queuePlace(queue: readonly string[], id: string): QueuePlace | undefined {
  const items: { fields: string[]; ref: string }[] = [];
  const deps: { sub: string; on: string; reason: string }[] = [];
  for (const line of queue) {
    const f = line.split("\t");
    if (f[0] === "item" && f.length >= 5) items.push({ fields: f, ref: f[1] as string });
    else if (f[0] === "dep" && f.length >= 4) deps.push({ sub: f[1] as string, on: f[2] as string, reason: f[3] as string });
  }
  const ref = `task:${id}`;
  let level = "";
  let position = "";
  let priority = "";
  const mine: Dependency[] = [];
  for (const item of items) {
    if (item.ref !== ref) continue;
    level = item.fields[2] as string;
    position = item.fields[3] as string;
    priority = item.fields[4] as string;
    for (const d of deps) if (d.sub === item.ref) mine.push({ on: d.on, reason: d.reason });
  }
  if (level === "") return undefined;
  let before = 0;
  let count = 0;
  for (const item of items) {
    if (item.fields[2] !== level) continue;
    count++;
    if (awkNumber(item.fields[3] as string) < awkNumber(position)) before++;
  }
  return { level, priority, rank: before + 1, count, deps: mine };
}

export interface PauseRequest {
  readonly at: string;
  readonly reason: string;
}

/** `jig_pause_request`: the first `request` line for `task:<id>` of kind `pause`: when it was made, and why. */
export function pauseRequest(queue: readonly string[], id: string): PauseRequest | undefined {
  const head = `request\ttask:${id}\tpause\t`;
  for (const line of queue) {
    if (!line.startsWith(head)) continue;
    let rest = line.slice(head.length);
    const tab = rest.indexOf("\t");
    const at = tab < 0 ? rest : rest.slice(0, tab);
    let reason = "";
    if (tab >= 0) {
      rest = rest.slice(tab + 1);
      const next = rest.indexOf("\t");
      reason = next < 0 ? rest : rest.slice(0, next);
    }
    return { at, reason };
  }
  return undefined;
}

/**
 * `jig_utc_ago`: how long ago a UTC `YYYY-MM-DDTHH:MM:SSZ` time was, in words ("just now", "12 min", "3 h",
 * "2 days"); empty when it does not parse.
 */
export function utcAgo(clock: Clock, iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/.exec(iso);
  if (m === null) return "";
  const [y, mo, d, h, mi, s] = m.slice(1).map(Number) as [number, number, number, number, number, number];
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 60) return "";
  const past = Math.floor(Date.UTC(y, mo - 1, d, h, mi, s) / 1000);
  const diff = clock.epoch() - past;
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.trunc(diff / 60)} min`;
  if (diff < 172800) return `${Math.trunc(diff / 3600)} h`;
  return `${Math.trunc(diff / 86400)} days`;
}
