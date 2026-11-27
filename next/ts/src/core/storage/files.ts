// Small file-system questions and writes shared by the readers above: `[ -f ]`, `[ -d ]`, `[ -L ]`,
// `cd -P && pwd -P`, and a write that goes through a temporary and a rename.

import fs from "node:fs";

export function isFile(p: string): boolean {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

export function isDir(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

export function isSymlink(p: string): boolean {
  try {
    return fs.lstatSync(p).isSymbolicLink();
  } catch {
    return false;
  }
}

/** `cd -P <p> && pwd -P`: the physical path, or undefined when it cannot be entered. */
export function physicalDir(p: string): string | undefined {
  try {
    if (!fs.statSync(p).isDirectory()) return undefined;
    return fs.realpathSync(p);
  } catch {
    return undefined;
  }
}

export function readText(p: string): string | undefined {
  try {
    return fs.readFileSync(p, "utf8");
  } catch {
    return undefined;
  }
}

/** Write through `<file>.tmp.<pid>` and a rename; false (the temporary removed) when it fails. */
export function writeViaTemp(file: string, text: string): boolean {
  const tmp = `${file}.tmp.${process.pid}`;
  try {
    fs.writeFileSync(tmp, text);
    fs.renameSync(tmp, file);
    return true;
  } catch {
    try {
      fs.rmSync(tmp, { force: true });
    } catch {
      // nothing to do
    }
    return false;
  }
}

export function makeDirs(p: string): boolean {
  try {
    fs.mkdirSync(p, { recursive: true });
    return true;
  } catch {
    return false;
  }
}

/** `[ -f p ] && [ -r p ]`. */
export function isReadableFile(p: string): boolean {
  try {
    if (!fs.statSync(p).isFile()) return false;
    fs.accessSync(p, fs.constants.R_OK);
    return true;
  } catch {
    return false;
  }
}

/** `sed '/^#/d;/^$/d' file`: the lines of a file without comments and empty lines; nothing when it cannot be read. */
export function readDataLines(p: string): string[] {
  const text = readText(p);
  if (text === undefined) return [];
  return text.split("\n").filter((l) => l !== "" && !l.startsWith("#"));
}
