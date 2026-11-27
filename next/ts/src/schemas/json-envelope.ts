// The envelope every `--json` read prints (schemas/json.md): one line, `data` on success,
// `error` when the command refused. `error.code` is any code-shaped word, not only the ones this
// version knows: a program treats a code it does not know as `failed`.

import { z } from "zod";

const base = {
  schema: z.literal(1),
  revision: z.number().int().nonnegative(),
  generated_at: z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/),
};

export const JsonEnvelopeOk = z.object({
  ...base,
  data: z.unknown(),
});

export const JsonEnvelopeError = z.object({
  ...base,
  error: z.object({
    code: z.string().regex(/^[a-z]+(-[a-z]+)*$/),
    message: z.string(),
  }),
});

export const JsonEnvelope = z.union([JsonEnvelopeOk, JsonEnvelopeError]);

export type JsonEnvelope = z.infer<typeof JsonEnvelope>;
