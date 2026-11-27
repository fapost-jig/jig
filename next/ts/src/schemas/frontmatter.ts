// The frontmatter of a knowledge document, read with the YAML failsafe schema: every scalar is a
// string, and a value is a string, a list or a map of those.

import { z } from "zod";

export type FrontmatterValue = string | FrontmatterValue[] | { [key: string]: FrontmatterValue };

export const FrontmatterValue: z.ZodType<FrontmatterValue> = z.lazy(() =>
  z.union([z.string(), z.array(FrontmatterValue), z.record(z.string(), FrontmatterValue)]),
);

export const Frontmatter = z.record(z.string(), FrontmatterValue);

export type Frontmatter = z.infer<typeof Frontmatter>;
