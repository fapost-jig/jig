# Frontmatter: where the YAML reader differs from bash

The frontmatter of a knowledge document is read in bash by `fm_get` and `fm_list`
(`scripts/lib/frontmatter.sh`, a flat subset read line by line) and in TypeScript by the `yaml`
library with the failsafe schema (`src/core/storage/frontmatter.ts`). On every document of this
repository they agree (`test/frontmatter-bash.test.ts` sweeps them all). On inputs outside what the
documents hold they differ in the ways below; each is meant, and `test/frontmatter-bash.test.ts`
checks that each still answers as written here.

Unlike `state`, `config.yaml` and `profile.yaml`, which are read line by line in TypeScript too
(`flat.ts`), frontmatter is real YAML, so the differences are the ones between a YAML reader and a
pattern reader. Where bash silently reads something a YAML reader refuses, the refusal is the
better answer: a document that bash accepts by accident is reported with its line.

### hash-in-quotes
Input: `summary: "a # b"`. Bash: `"a` (cut at the first `#`, a quote left over). TypeScript: `a # b`.
Acceptable: the YAML answer is what the author wrote; no document relies on bash's cut.

### colon-in-plain-scalar
Input: `summary: Text with: a colon`. Bash: the whole text. TypeScript: error with the line (YAML
forbids a `: ` inside a plain scalar). Acceptable: the document is invalid YAML and every other tool
reads it as an error; the fix is to quote it.

### single-quotes
Input: `summary: 'quoted'`. Bash: `'quoted'` (only double quotes are stripped). TypeScript: `quoted`.
Acceptable: YAML semantics; no document uses single quotes.

### duplicate-key
Input: `id: first` then `id: second`. Bash: `first`. TypeScript: error. Acceptable: a duplicate is a
mistake that bash hides by taking the first.

### comma-in-quoted-inline-item
Input: `paths: ["a,b", c]`. Bash: `"a`, `b"`, `c` (splits at every comma). TypeScript: `a,b`, `c`.
Acceptable: YAML semantics; a path with a comma was unreadable in bash.

### unclosed-inline-list
Input: `paths: [a, b`. Bash: no scalar and no list (silently nothing). TypeScript: error. Acceptable:
a document that loses its paths without a word is the failure to avoid.

### unindented-block-list
Input: `paths:` then `- a`, `- b`. Bash: nothing (only a two-space `  - ` is an item). TypeScript:
`a`, `b`. Acceptable: valid YAML that bash ignores; the TypeScript answer is the intended one.

### four-space-block-list
Input: items indented by four spaces. Bash: nothing. TypeScript: `a`, `b`. Acceptable: as above.

### hash-in-inline-item
Input: `paths: [a#b, c]`. Bash: `a#b`, `c`. TypeScript: `a#b`, `c`. The same answer; listed because a
`#` without a space before it is a comment in bash's scalar rule (`fm_get`) but not in its inline-list rule, and in YAML
it is not a comment either. No difference to accept.
