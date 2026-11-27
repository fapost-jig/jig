// Bundles the CLI into one file, dist/jig.mjs, with esbuild. Run with `npm run bundle`.
//
// The file runs on Node alone: everything it needs from node_modules is inside it, and it imports
// nothing but `node:*` (tools/check-deps.ts holds that). The metafile is written beside it, which is
// how check-deps knows which packages ended up in the bundle.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build as esbuild } from "esbuild";
import type { Metafile } from "esbuild";

export const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/** JIG_VERSION as scripts/lib/version.sh declares it: the version a bundle prints when no framework directory is found. */
export function declaredJigVersion(): string {
  const file = path.resolve(packageRoot, "..", "..", "scripts", "lib", "version.sh");
  const m = /^JIG_VERSION="([^"]+)"/m.exec(fs.readFileSync(file, "utf8"));
  if (!m?.[1]) throw new Error(`no JIG_VERSION in ${file}`);
  return m[1];
}

export interface BundleResult {
  readonly outfile: string;
  readonly metafile: Metafile;
}

export interface BundleOpts {
  /** Another entry point, for a test that needs the bundler to pull dependencies in. */
  readonly entry?: string;
}

export async function bundle(outDir: string, opts: BundleOpts = {}): Promise<BundleResult> {
  const outfile = path.join(outDir, "jig.mjs");
  const result = await esbuild({
    entryPoints: [opts.entry ?? path.join(packageRoot, "src", "cli", "main.ts")],
    outfile,
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node22",
    // yaml is CommonJS and asks for the built-in `process` with a bare require(); an ES module has no `require`,
    // so the bundle makes one (esbuild's own stand-in throws "Dynamic require of ..." at load otherwise).
    banner: {
      js: [
        "#!/usr/bin/env node",
        'import { createRequire as __jigCreateRequire } from "node:module";',
        "const require = __jigCreateRequire(import.meta.url);",
      ].join("\n"),
    },
    define: { __JIG_VERSION__: JSON.stringify(declaredJigVersion()) },
    // yaml names two built-ins without the `node:` prefix; the bundle imports only `node:*` (check-deps).
    alias: { process: "node:process", buffer: "node:buffer" },
    legalComments: "none",
    metafile: true,
    logLevel: "warning",
  });
  fs.writeFileSync(path.join(outDir, "jig.meta.json"), JSON.stringify(result.metafile));
  fs.chmodSync(outfile, 0o755);
  return { outfile, metafile: result.metafile };
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const outDir = path.join(packageRoot, "dist");
  fs.mkdirSync(outDir, { recursive: true });
  const { outfile } = await bundle(outDir);
  console.log(`bundle: ${path.relative(process.cwd(), outfile) || outfile} (${fs.statSync(outfile).size} bytes)`);
}
