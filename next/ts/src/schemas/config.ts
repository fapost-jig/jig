// A config file (`.ai/config.yaml`, `.ai/config.local.yaml`) as a map of its keys to the text bash reads.
// Keys are `section.key`, values are plain strings; a list is an inline `[a, b]` kept as text and
// split by the caller (storage/flat.ts, inlineList).

import { z } from "zod";

export const Config = z.record(z.string().regex(/^[A-Za-z0-9_.-]+$/), z.string());

export type Config = z.infer<typeof Config>;
