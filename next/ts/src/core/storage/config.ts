// `.ai/config.yaml` and `.ai/config.local.yaml`, layered as bash's `cfg` layers them (ADR-0038).
//
// The local file answers only for keys in JIG_CFG_LOCAL_KEYS, and a key in JIG_CFG_LOCAL_ONLY_KEYS never
// reads the project's file. An empty value falls through to the next layer. The local file of a worktree
// is the one in the clone's main checkout (`jig_config_clone_root`, storage/revision.ts).

import fs from "node:fs";
import path from "node:path";
import type { Ctx } from "../context.ts";
import { configValue, inlineList } from "./flat.ts";
import { cloneRoot } from "./revision.ts";
import type { LocalKeyLists } from "./framework.ts";

function readText(file: string): string | undefined {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return undefined;
  }
}

export function projectConfigFile(ctx: Pick<Ctx, "root">): string {
  return path.join(ctx.root, ".ai", "config.yaml");
}

export function localConfigFile(ctx: Pick<Ctx, "root">): string {
  return path.join(cloneRoot(ctx.root), ".ai", "config.local.yaml");
}

/** `_cfg_read_v` on one file: undefined when the file is missing or no line sets the key. */
export function readConfigFile(file: string, key: string): string | undefined {
  const text = readText(file);
  return text === undefined ? undefined : configValue(text, key);
}

export type ConfigLayer = "local" | "project" | "";

/** `_cfg_layered_v`: the value and the layer that gave it (empty when no file answers). */
export function layeredConfig(ctx: Pick<Ctx, "root">, keys: LocalKeyLists, key: string): { value: string; layer: ConfigLayer } {
  let value = "";
  let layer: ConfigLayer = "";
  if (keys.local.has(key)) {
    value = readConfigFile(localConfigFile(ctx), key) ?? "";
    if (value !== "") layer = "local";
  }
  if (value === "" && !keys.localOnly.has(key)) {
    value = readConfigFile(projectConfigFile(ctx), key) ?? "";
    if (value !== "") layer = "project";
  }
  return { value, layer };
}

/** `cfg <key> [default]`. */
export function cfg(ctx: Pick<Ctx, "root">, keys: LocalKeyLists, key: string, fallback = ""): string {
  const { value } = layeredConfig(ctx, keys, key);
  return value === "" ? fallback : value;
}

/** `cfg_list_lines <key>`. */
export function cfgList(ctx: Pick<Ctx, "root">, keys: LocalKeyLists, key: string): string[] {
  const raw = cfg(ctx, keys, key);
  return raw === "" ? [] : inlineList(raw);
}
