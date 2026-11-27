// The clock seam (scripts/lib/common.sh, "the clock").
//
// Every reading of the current time goes through here. A test pins it with
// JIG_NOW=<seconds since the epoch>; unset or empty means the real clock. The rule is
// bash's `jig_now_valid`: digits only, and at most 14 of them.

import { JigError } from "./errors.ts";

export interface Clock {
  /** Seconds since the epoch. */
  epoch(): number;
}

export type Env = Readonly<Record<string, string | undefined>>;

/** Throws `usage` with bash's message when JIG_NOW is not seconds since the epoch. */
export function checkJigNow(env: Env): void {
  const v = env["JIG_NOW"] ?? "";
  if (/[^0-9]/.test(v) || v.length > 14) {
    throw new JigError("usage", `JIG_NOW must be seconds since the epoch, got '${v}'`);
  }
}

export function systemClock(env: Env): Clock {
  checkJigNow(env);
  const pinned = env["JIG_NOW"] ?? "";
  if (pinned === "") return { epoch: () => Math.floor(Date.now() / 1000) };
  const seconds = Number(pinned);
  return { epoch: () => seconds };
}

/** A clock that always answers `seconds`; for tests. */
export function fixedClock(seconds: number): Clock {
  return { epoch: () => seconds };
}

function pad(n: number, width = 2): string {
  return String(n).padStart(width, "0");
}

/** `jig_today`: the local date, `YYYY-MM-DD`. */
export function today(clock: Clock): string {
  const d = new Date(clock.epoch() * 1000);
  return `${pad(d.getFullYear(), 4)}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** `jig_now_utc`: `YYYY-MM-DDTHH:MM:SSZ`. */
export function nowUtc(clock: Clock): string {
  const d = new Date(clock.epoch() * 1000);
  return (
    `${pad(d.getUTCFullYear(), 4)}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}` +
    `T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}Z`
  );
}
