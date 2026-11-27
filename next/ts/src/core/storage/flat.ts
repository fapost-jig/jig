// Readers of Jig's flat files, line by line, exactly as bash reads them.
//
// `state`, `.ai/config.yaml`, `.ai/config.local.yaml` and `profile.yaml` look like YAML and are
// not: bash reads them with `while read` and a pattern, so `{selection}`, `a: b: c` and `a#b`
// mean what that reading makes of them. A YAML library reads each of those differently, and a
// setting that silently changes is the failure this module exists to prevent (design.md,
// "Хранилище"). Pure functions over text; the file system belongs to the callers in this
// directory.
//
// The blank class below is POSIX `[[:space:]]` in the C locale, which bash's own patterns use.

const BLANK = " \t\n\v\f\r";

function isBlank(ch: string | undefined): boolean {
  return ch !== undefined && BLANK.includes(ch);
}

/** The lines of a file as `while IFS= read -r line || [ -n "$line" ]` sees them. */
export function lines(text: string): string[] {
  if (text === "") return [];
  const parts = text.split("\n");
  if (parts[parts.length - 1] === "") parts.pop();
  return parts;
}

export function trimStart(s: string): string {
  let i = 0;
  while (i < s.length && isBlank(s[i])) i++;
  return s.slice(i);
}

export function trimEnd(s: string): string {
  let j = s.length;
  while (j > 0 && isBlank(s[j - 1])) j--;
  return s.slice(0, j);
}

export function trim(s: string): string {
  return trimEnd(trimStart(s));
}

// --- config.yaml, config.local.yaml, profile.yaml: `_cfg_read_v` ---------------------

const CONFIG_KEY = /^[A-Za-z0-9_.-]+$/;

/**
 * The value of `key` in a config or profile file's text, or undefined when no line sets it.
 *
 * The first line matching `^<key>:[[:space:]]*` decides, even when its value is empty. The value
 * is cut at the FIRST `#` (with no space before it too) and its trailing blanks are removed.
 * Like bash, the key is used as a pattern, so `.` stands for any one character: a line
 * `notify_telegram_token:` answers for `notify.telegram.token`.
 */
export function configValue(text: string, key: string): string | undefined {
  if (!CONFIG_KEY.test(key)) throw new Error(`not a config key: ${key}`);
  const re = new RegExp(`^${key}:[ \\t\\n\\v\\f\\r]*`, "us");
  for (const line of lines(text)) {
    const m = re.exec(line);
    if (!m) continue;
    let value = line.slice(m[0].length);
    const hash = value.indexOf("#");
    if (hash >= 0) value = value.slice(0, hash);
    return trimEnd(value);
  }
  return undefined;
}

/**
 * `cfg_list_lines`: the items of an inline list `[a, b]`. Outer brackets are removed, the rest
 * is split at commas, each item is trimmed and loses one pair of surrounding double quotes, and
 * empty items are dropped. A bare scalar is a one-item list; `a, b` without brackets splits the same way.
 */
export function inlineList(raw: string): string[] {
  let v = raw;
  if (v.startsWith("[") && v.endsWith("]")) v = v.slice(1, -1);
  const out: string[] = [];
  for (const piece of v.split(",")) {
    let item = trim(piece);
    if (item.length >= 2 && item.startsWith('"') && item.endsWith('"')) item = item.slice(1, -1);
    if (item !== "") out.push(item);
  }
  return out;
}

// --- state: `jig_task_state_var` --------------------------------------------------------

/**
 * The value of `key` in a task state file's text, or undefined when no line has the key.
 *
 * The first line starting `<key>:` wins. The value is what follows the colon with every leading
 * blank removed; trailing blanks (and a carriage return) are part of it.
 */
export function stateValue(text: string, key: string): string | undefined {
  const prefix = `${key}:`;
  for (const line of lines(text)) {
    if (line.startsWith(prefix)) return trimStart(line.slice(prefix.length));
  }
  return undefined;
}
