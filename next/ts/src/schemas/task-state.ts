// The keys of a task's `state` file (schemas/state.md), and the shape a read is validated against.
//
// Every value is a string: the file is flat `key: value` lines and bash treats every value as
// text. The list of keys is the table of schemas/state.md; test/schemas.test.ts reads that
// table and fails when the two differ.

import { z } from "zod";

export const TASK_STATE_KEYS = [
  "task_id",
  "issue",
  "branch",
  "base_commit",
  "base_branch",
  "executor_implement_runtime",
  "executor_review_runtime",
  "executor_implement_model",
  "executor_review_model",
  "executor_implement_runtime_source",
  "executor_review_runtime_source",
  "executor_implement_model_source",
  "executor_review_model_source",
  "class",
  "class_lowered_from",
  "class_lowered_reason",
  "out_of_order_over",
  "out_of_order_reason",
  "route_evidence",
  "status",
  "abandoned_at",
  "abandoned_reason",
  "moved_to",
  "archived_at",
  "archived_reason",
  "absorbed_into",
  "absorbs",
  "absorbs_partly",
  "partly_in",
  "archived_from",
  "knowledge_consolidated",
  "autopilot",
  "autopilot_handover",
  "autopilot_answered",
  "autopilot_repairs",
  "autopilot_mode",
  "autopilot_phase",
  "gate",
  "gate_design",
  "gate_by",
  "share",
  "setup",
  "notes_through",
  "pr_url",
  "pr_into",
  "promote_url",
  "park_resumed_at",
  "triage_task",
  "triage_of",
  "route_depth",
  "domains",
  "paused",
  "paused_at",
  "paused_reason",
  "paused_stash",
  "paused_stash_applied",
  "created_at",
  "updated_at",
] as const;

export type TaskStateKey = (typeof TASK_STATE_KEYS)[number];

/** `task_id` as schemas/state.md writes it: no leading dot, so `.`, `..` and hidden names are impossible. */
export const TASK_ID_PATTERN = "^[A-Za-z0-9][A-Za-z0-9._-]*$";

const shape = Object.fromEntries(
  TASK_STATE_KEYS.map((k) => [k, z.string().optional()]),
) as Record<TaskStateKey, z.ZodOptional<z.ZodString>>;

export const TaskState = z.object({
  ...shape,
  task_id: z.string().regex(new RegExp(TASK_ID_PATTERN)).optional(),
});

export type TaskState = z.infer<typeof TaskState>;

export function isTaskStateKey(key: string): key is TaskStateKey {
  return (TASK_STATE_KEYS as readonly string[]).includes(key);
}
