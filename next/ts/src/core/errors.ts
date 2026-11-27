// The one error type of the core, and the closed set of failure codes it can carry.
//
// The codes are the contract of schemas/json.md ("Failure codes"): a program reads
// `error.code` from a `--json` refusal. `failed` is the code of any refusal that names
// none. Keep this list equal to the table there; test/errors.test.ts reads that table
// and fails on a difference.

export const FAILURE_CODES = [
  "usage",
  "not-a-repository",
  "not-initialised",
  "stale-revision",
  "not-found",
  "not-paused",
  "already-paused",
  "wrong-checkout",
  "stash-conflict",
  "not-closable",
  "already-exists",
  "already-filed",
  "git-not-allowed",
  "write-busy",
  "branch-checked-out",
  "branch-diverged",
  "branch-has-other-commits",
  "base-not-on-origin",
  "write-still-waits",
  "tree-in-the-way",
  "commit-refused",
  "epic-missing",
  "not-linkable",
  "not-proposed",
  "not-on-base",
  "not-on-branch",
  "source-missing",
  "upgrade-blocked",
  "unreleased-source",
  "unknown-key",
  "not-local",
  "invalid-value",
  "secret-key",
  "not-merged",
  "not-on-staging",
  "behind-staging",
  "carries-staging",
  "base-conflict",
  "shallow-clone",
  "forge-unavailable",
  "ci-red",
  "ci-pending",
  "ci-none",
  "not-approved",
  "review-required",
  "conflict",
  "draft",
  "mergeable-unknown",
  "forge-refused",
  "no-pull-request",
  "pull-request-closed",
  "wrong-flow",
  "not-ready",
  "not-shipped",
  "notes-stale",
  "reviewer-unknown",
  "autopilot-running",
  "autopilot-stopped",
  "no-gate",
  "already-archived",
  "not-archived",
  "wrong-status",
  "already-closed",
  "ship-running",
  "git-level",
  "failed",
] as const;

export type FailureCode = (typeof FAILURE_CODES)[number];

export class JigError extends Error {
  readonly code: FailureCode;

  constructor(code: FailureCode, message: string) {
    super(message);
    this.name = "JigError";
    this.code = code;
  }
}

/** A refusal with no code of its own, bash's `jig_die`. */
export function die(message: string): JigError {
  return new JigError("failed", message);
}

/** What a program reads when the code is one it does not know: `failed`. */
export function asFailureCode(code: string): FailureCode {
  return (FAILURE_CODES as readonly string[]).includes(code) ? (code as FailureCode) : "failed";
}
