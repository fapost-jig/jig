// What every function of the core receives: no ambient process state is read below this.

import type { Clock, Env } from "./clock.ts";
import type { ExecFn } from "./exec.ts";

export interface Ctx {
  /** The project root (the git repository holding .ai/). */
  readonly root: string;
  readonly exec: ExecFn;
  readonly clock: Clock;
  readonly env: Env;
}
