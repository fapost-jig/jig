# Research — Stack migration

Facts gathered while the spec was discussed (2026-11-20 … 2026-11-23), each with its source.

## Jig today

- Size: `scripts/lib/` holds 42 files, ~58k lines of bash; 21 of them source others; `common.sh`
  ~7k lines, `task.sh` ~10k. About 3,900 command substitutions `$(…)` and ~1,100 `git` call sites.
- Tests: ~96k lines under `tests/`, ~5,200 cases. They drive the `jig` CLI from outside; 18 files
  source `scripts/lib/*.sh` and call functions directly. External tools are stubbed on `PATH`:
  `stub_gh` 164 uses, `stub_tool` 107, `stub_glab` 27.
- Profiles: 13 under `profiles/`, ~4.5k lines of `verify.sh`; every `verify.sh` sources
  `../../scripts/lib/profile.sh`. `profile.yaml` already declares each check's command, full and
  narrowed arguments; `verify.sh` holds the selection logic (`{selection}`), the "run everything"
  globs and the labels.
- CI, run 44709464527 on main (2026-11-20): Ubuntu 4 shards of 7–12 min, macOS 4 shards of
  21–24 min, Windows 10 shards of 30–42 min; some shards started 5–7 minutes late, waiting for a
  runner. The same test, `status::test_status_page_says_when_pull_request_data_is_stale`: 14 s on
  Linux, 25 s on macOS, 153 s on Windows.
- `scripts/lib/upgrade.sh` (~line 441): bash reads a script incrementally from an open descriptor,
  so replacing the files under a running bash process is unsafe.

## Other tools (read 2026-11-23, nothing of theirs was run)

- **ai-factory** (github.com/lee-to/ai-factory) — TypeScript, npm, ~15.5k lines in `src/`. Uses
  commander, `yaml` (`parseDocument` with `LineCounter`), semver; `git` through `spawnSync` with
  `shell: false`, `windowsHide` and `git -c core.fsmonitor=false -C <dir>`; an install receipt with
  source and installed hashes; JSON documents with `schema_version`; a hand-written stdio MCP server
  of ~60 lines; a swarm store on `node:sqlite`. Tests use `node:assert` plus the old bash suites run
  under a Node wrapper, which still needs bash on Windows; Windows CI covers one path test. Exits 75
  after `update` to ask the caller to re-run.
- **aif-handoff** (github.com/lee-to/aif-handoff) — TypeScript monorepo of 7 packages on Turbo,
  ~97k lines: zod 4, hono, drizzle with `better-sqlite3` (breaks with `ERR_DLOPEN_FAILED` when Node
  changes), the MCP SDK over stdio and HTTP, vitest, Stryker, Playwright; CI on Ubuntu only. A
  handoff between a human and an AI owner is a transaction guarded by an ownership revision; its
  sync with ai-factory is last-write-wins on timestamps and needed a fix for epoch-zero times.
- **ai-workspace** (github.com/lee-to/ai-workspace) — Rust. Layers `models → db → services → cli |
  mcp`, where `cli` and `mcp` never import each other. Its cloud mode: an explicit `cloud push` of a
  JSON snapshot with a mandatory `schema_version`, unknown fields rejected, optimistic concurrency
  through `base_revision` (a stale base gets 409); the server is the same binary (`cloud serve`) on
  PostgreSQL with row-level security per tenant and external OIDC tokens. CI: Windows 8m42s, Ubuntu
  1m22s, macOS 1m53s.
- **HLV** (github.com/lee-to/hlv, hlv.cutcode.dev) — Rust. Typed YAML models, 17 JSON Schemas under
  `schema/` checked by tests, `--json` on every command, `update` split into the binary and the
  managed project files, an MCP server (27–29 tools) and a TUI dashboard, a workspace serving several
  projects. CI: Windows 2m25s, Ubuntu 48s.

## The hosted service, as ai-workspace shapes it

Kept for Jig UI's spec, where the idea of a hosted or self-hosted view of a company's projects
lives: the client pushes a versioned snapshot explicitly; the server rejects fields it does not
know and a stale revision; the server ships in the same artifact as the client; authentication is
delegated to an OIDC provider; tenants are isolated by row-level security. No web UI, pull or
background sync exists there yet.
