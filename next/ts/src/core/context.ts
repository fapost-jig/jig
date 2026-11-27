// What every function of the core receives: no ambient process state is read below this.

import type { Clock, Env } from "./clock.ts";
import type { ExecFn } from "./exec.ts";
import type { LocalKeyLists } from "./storage/framework.ts";

export interface Ctx {
  /** The project root (the git repository holding .ai/). */
  readonly root: string;
  readonly exec: ExecFn;
  readonly clock: Clock;
  readonly env: Env;
}

/** Where a command's text goes; the core writes through it and never to the process. */
export interface Output {
  out(text: string): void;
  err(text: string): void;
}

/**
 * What the commands that read the project need besides `Ctx`: the two key lists of the framework's
 * `scripts/lib/config.sh`, and the framework's own directory (the `scripts/lib` it was found in).
 */
export interface JigCtx extends Ctx {
  readonly keys: LocalKeyLists;
  /** The framework's `scripts/lib`, or undefined when none was found (a bundle away from its checkout). */
  readonly lib: string | undefined;
  /** A seam for tests: runs between the queue's reading and the revision's claim of a pause being honoured. */
  readonly beforeQueueClaim?: (() => void) | undefined;
}
