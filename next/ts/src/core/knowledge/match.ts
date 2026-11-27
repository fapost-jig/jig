// How a knowledge document is matched to a change: its status, its `paths` globs, its domains.

/** `jig_knowledge_status_resolvable`: an allowlist, so a status nobody has heard of resolves nowhere. */
export function statusResolvable(status: string): boolean {
  return status === "active" || status === "accepted";
}

/**
 * `jig_glob_pattern_v` and the `case` it is matched in: `*` is the one wildcard, and it crosses `/`;
 * `**` and `**` followed by `/` collapse to `*`; a glob ending in `/` gains a trailing `*`; every
 * other character, `?` and `[...]` included, stands for itself.
 */
export function globRegExp(glob: string): RegExp {
  let g = glob.replaceAll("**/", "*").replaceAll("**", "*");
  if (g.endsWith("/")) g = `${g}*`;
  const source = g
    .split("*")
    .map((part) => part.replace(/[\\^$.*+?()[\]{}|]/g, "\\$&"))
    .join(".*");
  return new RegExp(`^${source}$`, "su");
}

/** `jig_path_matches_any`: whether `glob` matches at least one of `files` (empty lines are skipped). */
export function pathMatchesAny(glob: string, files: readonly string[]): boolean {
  const re = globRegExp(glob);
  return files.some((f) => f !== "" && re.test(f));
}

/** The words of a comma list as the shell reads them after `tr ',' ' '`. */
export function commaWords(list: string): string[] {
  return list.replaceAll(",", " ").split(/[ \t\n]+/).filter((w) => w !== "");
}
