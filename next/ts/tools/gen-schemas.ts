// Writes the JSON Schema of every schema in src/schemas/ to schemas/<name>.schema.json (committed).
// `--check` writes nothing and exits 1 when a committed file differs from what the code generates:
// the schemas are generated from zod, never edited, and a change to one shows up in review.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { z } from "zod";
import { Config, Frontmatter, JsonEnvelope, TaskState } from "../src/schemas/index.ts";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const schemasDir = path.join(root, "schemas");

const ALL = { "task-state": TaskState, config: Config, frontmatter: Frontmatter, "json-envelope": JsonEnvelope } as const;

/** name -> file text, as committed. */
export function generate(): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [name, schema] of Object.entries(ALL)) {
    out[`${name}.schema.json`] = `${JSON.stringify(z.toJSONSchema(schema), null, 2)}\n`;
  }
  return out;
}

/** The names of committed files that differ from what generate() makes, or are missing or extra. */
export function drift(dir = schemasDir): string[] {
  const want = generate();
  const bad: string[] = [];
  for (const [file, text] of Object.entries(want)) {
    let have: string | undefined;
    try {
      have = fs.readFileSync(path.join(dir, file), "utf8");
    } catch {
      have = undefined;
    }
    if (have !== text) bad.push(file);
  }
  if (fs.existsSync(dir)) {
    for (const f of fs.readdirSync(dir)) if (f.endsWith(".schema.json") && !(f in want)) bad.push(f);
  }
  return bad;
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.includes("--check")) {
    const bad = drift();
    if (bad.length > 0) {
      console.error(`gen-schemas: committed schemas differ from the code: ${bad.join(", ")}\nrun: npm run gen-schemas`);
      process.exit(1);
    }
    console.log("gen-schemas: schemas/*.schema.json match the code");
  } else {
    fs.mkdirSync(schemasDir, { recursive: true });
    for (const [file, text] of Object.entries(generate())) fs.writeFileSync(path.join(schemasDir, file), text);
    console.log(`gen-schemas: wrote ${Object.keys(ALL).length} files to schemas/`);
  }
}
