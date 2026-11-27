import assert from "node:assert/strict";
import { test } from "node:test";
import { checkJigNow, fixedClock, nowUtc, systemClock, today } from "../src/core/clock.ts";
import { JigError } from "../src/core/errors.ts";
import { bashLib } from "./helpers.ts";

test("an unset or empty JIG_NOW is the real clock", () => {
  for (const env of [{}, { JIG_NOW: "" }]) {
    const before = Math.floor(Date.now() / 1000);
    const at = systemClock(env).epoch();
    assert.ok(at >= before - 1 && at <= before + 2, `epoch ${at} is not the present`);
  }
});

test("a pinned JIG_NOW is the clock", () => {
  assert.equal(systemClock({ JIG_NOW: "1790000000" }).epoch(), 1790000000);
  assert.equal(systemClock({ JIG_NOW: "0" }).epoch(), 0);
});

test("a JIG_NOW that is not seconds since the epoch is refused with bash's message", () => {
  for (const bad of ["x", "12 3", "-5", "1.5", "123456789012345", "1e9"]) {
    assert.throws(
      () => checkJigNow({ JIG_NOW: bad }),
      (e: unknown) => e instanceof JigError && e.code === "usage" && e.message === `JIG_NOW must be seconds since the epoch, got '${bad}'`,
      bad,
    );
  }
  assert.doesNotThrow(() => checkJigNow({ JIG_NOW: "12345678901234" }));
});

test("the rule is bash's: the same values pass and fail", () => {
  const cases = ["", "0", "1790000000", "12345678901234", "123456789012345", "x", "1.5", "007"];
  for (const v of cases) {
    const bash = bashLib(process.cwd(), 'JIG_NOW=$1; if jig_now_valid; then echo ok; else echo bad; fi', [v], { TZ: "UTC" });
    let ts = "ok";
    try {
      checkJigNow({ JIG_NOW: v });
    } catch {
      ts = "bad";
    }
    assert.equal(ts, bash.stdout.trim(), `JIG_NOW=${JSON.stringify(v)}`);
  }
});

test("today is the local date and nowUtc the UTC stamp", () => {
  const clock = fixedClock(1790000000);
  assert.equal(nowUtc(clock), "2026-09-21T14:13:20Z");
  const d = new Date(1790000000 * 1000);
  const local = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  assert.equal(today(clock), local);
});

test("today and nowUtc agree with bash's jig_today and jig_now_utc in any time zone", () => {
  const saved = process.env["TZ"];
  try {
    for (const tz of ["UTC", "Pacific/Kiritimati", "America/Los_Angeles"]) {
      const bash = bashLib(process.cwd(), 'printf "%s\\n%s\\n%s\\n" "$(jig_today)" "$(jig_now_utc)" "$(date +%z)"', [], { JIG_NOW: "1790000000", TZ: tz });
      assert.equal(bash.code, 0, bash.stderr);
      // Git for Windows' `date` has no zone database: a named zone it cannot read is UTC to it,
      // so bash's answer there says nothing about the zone and the zone is not compared.
      if (tz !== "UTC" && bash.stdout.split("\n")[2] === "+0000") continue;
      const [day, utc] = bash.stdout.split("\n");
      process.env["TZ"] = tz;
      assert.equal(utc, nowUtc(fixedClock(1790000000)), tz);
      assert.equal(day, today(fixedClock(1790000000)), tz);
    }
  } finally {
    if (saved === undefined) delete process.env["TZ"];
    else process.env["TZ"] = saved;
  }
});
