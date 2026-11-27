// The entry point: `node src/cli/main.ts` in development, the same file bundled into dist/jig.mjs.

import path from "node:path";
import { fileURLToPath } from "node:url";
import { run } from "./run.ts";

// Replaced by tools/bundle.ts; undefined when running from source.
declare const __JIG_VERSION__: string | undefined;

const baked = typeof __JIG_VERSION__ === "string" ? __JIG_VERSION__ : undefined;

process.exitCode = await run({
  argv: process.argv.slice(2),
  env: process.env,
  cwd: process.cwd(),
  entryDir: path.dirname(fileURLToPath(import.meta.url)),
  bakedVersion: baked,
  io: {
    out: (text) => process.stdout.write(text),
    err: (text) => process.stderr.write(text),
  },
});
