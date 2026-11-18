# Tests for `jig upgrade` (domains/install decision table, ADR-0003).
# shellcheck shell=bash

# _mk_source_v2 <dest> — a modified copy of $JIG_HOME: a changed profile
# script, a bumped version, and a brand-new skill (with a slash invocation,
# so the codex transform is exercised on install too).
_mk_source_v2() {
  fixture_source_v2_copy "$1"
}

# _unbump_source <dest> — give a source made by _mk_source_v2 the running
# version back, so the running code carries out the upgrade itself instead of
# handing it to the source's newer dispatcher. The tests that are about the old
# code doing the work need exactly that.
_unbump_source() {
  local tmp_version="$1/scripts/lib/version.sh.tmp"
  cp "$JIG_HOME/scripts/lib/version.sh" "$tmp_version"
  mv "$tmp_version" "$1/scripts/lib/version.sh"
  fixture_release_source "$1"
}

test_upgrade_requires_initialised_project() {
  fixture_repo
  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "not initialised"
}

test_upgrade_from_without_value_dies() {
  fixture_jig_repo
  run jig upgrade --from
  assert_eq 1 "$RC"
  assert_contains "$OUT" "requires a value"
}

test_upgrade_link_mode_is_noop_when_everything_already_linked() {
  skip_unless_symlinks
  fixture_repo
  jig init --from "$JIG_HOME" --link >/dev/null
  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "0 placed"
  assert_contains "$OUT" "manifest updated"
  assert_not_contains "$OUT" "link .ai"
}

# Reproduces the reported case (2026-09-22): `jig upgrade --from <another
# checkout>` in a link-mode project conflicts on every link, places nothing,
# and used to repoint jig.source at that checkout all the same — after which
# a plain `jig upgrade` would have read from a source no file came from.
test_upgrade_link_mode_keeps_manifest_when_every_link_conflicts() {
  skip_unless_symlinks
  fixture_repo
  jig init --from "$JIG_HOME" --link >/dev/null
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-other.XXXXXX")
  src=$(cd "$src" && pwd) # $TMPDIR can end in a slash; the manifest records a clean path
  cp -R "$JIG_HOME"/. "$src"/
  fixture_release_source "$src"
  cp .ai/manifest manifest.before.tmp

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "keep-conflict .ai/scripts"
  assert_not_contains "$OUT" "link .ai/scripts"
  assert_contains "$OUT" "0 placed"
  assert_contains "$OUT" "manifest unchanged"
  assert_contains "$OUT" "jig init --link --from $src"
  diff -q manifest.before.tmp .ai/manifest >/dev/null \
    || fail "manifest changed although nothing was linked"
  assert_file_contains .ai/manifest "jig.source: $JIG_HOME"

  rm -rf "$src"
}

# The other half of the rule: the recorded source may always be written back,
# placed or not. In link mode the project runs that checkout's scripts
# directly, so jig.version has to keep following it — otherwise `jig status`
# reports a version mismatch that no `jig upgrade` can ever clear.
test_upgrade_link_mode_refreshes_version_of_the_recorded_source() {
  skip_unless_symlinks
  fixture_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-same.XXXXXX")
  src=$(cd "$src" && pwd) # $TMPDIR can end in a slash; the manifest records a clean path
  cp -R "$JIG_HOME"/. "$src"/
  fixture_release_source "$src"
  jig init --from "$src" --link >/dev/null
  local tmp_version="$src/scripts/lib/version.sh.tmp"
  sed 's/^JIG_VERSION=.*/JIG_VERSION="9.9.9"/' "$src/scripts/lib/version.sh" > "$tmp_version"
  mv "$tmp_version" "$src/scripts/lib/version.sh"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "0 placed"
  assert_contains "$OUT" "manifest updated"
  assert_file_contains .ai/manifest "jig.version: 9.9.9"
  assert_file_contains .ai/manifest "jig.source: $src"

  rm -rf "$src"
}

# Reproduces the gap: activating a profile in config.yaml after `init --link`
# left `jig upgrade` a pure no-op, so `jig verify`'s "run jig upgrade" hint
# was a dead end (domains/install).
test_upgrade_link_mode_creates_missing_profile_symlink() {
  skip_unless_symlinks
  fixture_repo
  jig init --from "$JIG_HOME" --link --profiles generic >/dev/null
  assert_no_file .ai/profiles/shell
  cat > .ai/config.yaml <<'EOF'
profiles: [generic, shell]
adapters: [claude, codex]
EOF

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "link .ai/profiles/shell"

  assert_symlink .ai/profiles/shell
  case "$(readlink .ai/profiles/shell)" in
    /*) fail "symlink target is absolute: $(readlink .ai/profiles/shell)" ;;
  esac
  assert_file .ai/profiles/shell/verify.sh

  run jig verify --profile shell
  # The freshly linked shell profile finds no linter and no test runner here,
  # so every check skips and the run says it checked nothing, exit 3
  # (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass). What
  # this test is about — that the symlink was made and is usable — is the
  # RESULT line, not the exit code.
  assert_eq 3 "$RC"
  assert_contains "$OUT" "RESULT shell: skip"

  # a non-symlink file in the way is a conflict, not an overwrite
  run jig verify --list --profile shell
  assert_contains "$OUT" "shell: installed"
}

# A directory of the project's own under a stock profile's name is a name clash
# of the stack (adr-20261117-profiles-lists-top-layers-and-jig-resolves-the-stack):
# one refusal naming both, not a keep-conflict per file.
test_upgrade_link_mode_refuses_a_project_directory_under_a_stock_name_and_keeps_it() {
  skip_unless_symlinks
  fixture_repo
  jig init --from "$JIG_HOME" --link --profiles generic >/dev/null
  cat > .ai/config.yaml <<'EOF'
profiles: [generic, shell]
adapters: [claude, codex]
EOF
  mkdir -p .ai/profiles/shell
  echo "pre-existing, not a symlink" > .ai/profiles/shell/verify.sh

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "profile '.ai/profiles/shell' is the project's own, but 'shell' is a stock profile"
  assert_no_file .ai/profiles/shell/profile.yaml
  assert_file_contains .ai/profiles/shell/verify.sh "pre-existing, not a symlink"
}

# Reproduces the Windows Git Bash gap: `ln -s` copies instead of linking, so
# a link-mode project must refuse rather than silently place a copy where the
# manifest expects a symlink (jig_link_detect, common.sh).
test_upgrade_link_mode_refuses_when_only_copying_links_are_available() {
  skip_unless_symlinks
  fixture_repo
  jig init --from "$JIG_HOME" --link --profiles generic >/dev/null
  assert_no_file .ai/profiles/shell
  cat > .ai/config.yaml <<'EOF'
profiles: [generic, shell]
adapters: [claude, codex]
EOF
  local before lndir
  before=$(git status --porcelain)
  lndir=$(stub_ln_copy_dir)
  export PATH="$lndir:$PATH"

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "installed in link mode, which needs symbolic links"
  assert_no_file .ai/profiles/shell
  assert_eq "$before" "$(git status --porcelain)" "a refused upgrade must change nothing"

  run jig upgrade --from "$JIG_HOME" --dry-run
  assert_eq 1 "$RC"
  assert_contains "$OUT" "installed in link mode, which needs symbolic links"
  assert_no_file .ai/profiles/shell
  assert_eq "$before" "$(git status --porcelain)" "a refused dry-run must change nothing"
}

test_upgrade_dry_run_makes_no_changes() {
  fixture_jig_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2 "$src"
  cp .ai/manifest manifest.before.tmp

  run jig upgrade --from "$src" --dry-run
  assert_eq 0 "$RC"
  assert_contains "$OUT" "replace .ai/profiles/generic/verify.sh"
  assert_contains "$OUT" "install .codex/skills/jig-newthing/SKILL.md"

  diff -q manifest.before.tmp .ai/manifest >/dev/null || fail "manifest changed during --dry-run"
  assert_no_file .codex/skills/jig-newthing
  assert_not_contains "$(cat .ai/profiles/generic/verify.sh)" "v2 marker"

  rm -rf "$src"
}

# Exercises every row of the domains/install decision table in one pass:
# replace, keep-modified, install, keep-conflict, delete, keep-orphaned-modified.
test_upgrade_decision_table_full() {
  fixture_jig_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2 "$src"

  # keep-modified: local edit to a file that is unchanged in source-v2.
  printf '\n# local edit\n' >> .ai/scripts/lib/config.sh

  # keep-orphaned-modified: local edit to a file removed in source-v2.
  printf '\n# local edit\n' >> .ai/scripts/lib/status.sh
  rm -f "$src/scripts/lib/status.sh"

  # delete: unmodified file removed in source-v2.
  rm -f "$src/profiles/generic/profile.yaml"
  # Released again: a source with local changes is no release.
  fixture_release_source "$src"

  # keep-conflict: a path the new skill would install, pre-created locally
  # with content that does not match the source and is not manifest-tracked.
  mkdir -p .claude/skills/jig-newthing
  echo "pre-existing, not from jig" > .claude/skills/jig-newthing/SKILL.md

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"

  assert_contains "$OUT" "replace .ai/profiles/generic/verify.sh"
  assert_contains "$OUT" "keep-modified .ai/scripts/lib/config.sh"
  assert_contains "$OUT" "keep-orphaned-modified .ai/scripts/lib/status.sh"
  assert_contains "$OUT" "delete .ai/profiles/generic/profile.yaml"
  assert_contains "$OUT" "keep-conflict .claude/skills/jig-newthing/SKILL.md"
  assert_contains "$OUT" "install .codex/skills/jig-newthing/SKILL.md"
  # a genuinely unchanged file (scripts/jig itself) must not be reported
  assert_not_contains "$OUT" "replace .ai/scripts/jig"

  assert_file_contains .ai/profiles/generic/verify.sh "v2 marker"
  assert_file_contains .ai/scripts/lib/config.sh "local edit"
  assert_file_contains .ai/scripts/lib/status.sh "local edit"
  assert_no_file .ai/profiles/generic/profile.yaml
  assert_file_contains .claude/skills/jig-newthing/SKILL.md "pre-existing, not from jig"
  # shellcheck disable=SC2016
  assert_file_contains .codex/skills/jig-newthing/SKILL.md '$jig-newthing'

  assert_file_contains .ai/manifest "jig.version: 9.9.9"

  local claude_tracked codex_tracked profile_tracked
  claude_tracked=$(grep -c ' \.claude/skills/jig-newthing/SKILL\.md$' .ai/manifest)
  assert_eq 0 "$claude_tracked"
  codex_tracked=$(grep -c ' \.codex/skills/jig-newthing/SKILL\.md$' .ai/manifest)
  assert_eq 1 "$codex_tracked"
  profile_tracked=$(grep -c ' \.ai/profiles/generic/profile\.yaml$' .ai/manifest)
  assert_eq 0 "$profile_tracked"

  # re-running upgrade against the same source is a no-op from here
  cp .ai/manifest manifest.after.tmp
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "replace"
  assert_not_contains "$OUT" "install"
  assert_not_contains "$OUT" "runtime/working/other-session"
  diff -q manifest.after.tmp .ai/manifest >/dev/null || fail "manifest changed on a no-op rerun"

  rm -rf "$src"
}

# The same fork as link mode's, in copy mode: nothing installed, replaced or
# deleted means the project is still the install it was, so neither
# jig.source nor jig.version may move to the checkout it was offered.
test_upgrade_copy_mode_keeps_manifest_when_nothing_was_placed() {
  fixture_jig_repo
  local src before_version
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  src=$(cd "$src" && pwd) # $TMPDIR can end in a slash; the manifest records a clean path
  _mk_source_v2 "$src"
  before_version=$(sed -n 's/^jig\.version: //p' .ai/manifest)

  # Every path source-v2 would place is locally modified or occupied, so the
  # decision table ends with keep-modified/keep-conflict and nothing else.
  printf '\n# local edit\n' >> .ai/profiles/generic/verify.sh
  printf '\n# local edit\n' >> .ai/scripts/lib/version.sh
  mkdir -p .claude/skills/jig-newthing .codex/skills/jig-newthing
  echo "mine" > .claude/skills/jig-newthing/SKILL.md
  echo "mine" > .codex/skills/jig-newthing/SKILL.md
  cp .ai/manifest manifest.before.tmp

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "0 placed"
  assert_contains "$OUT" "manifest unchanged"
  assert_contains "$OUT" "jig init --from $src"
  assert_not_contains "$OUT" "jig init --link"
  diff -q manifest.before.tmp .ai/manifest >/dev/null \
    || fail "manifest changed although nothing was placed"
  assert_file_contains .ai/manifest "jig.source: $JIG_HOME"
  assert_file_contains .ai/manifest "jig.version: $before_version"

  rm -rf "$src"
}

# Moving a project onto another checkout stays possible: an upgrade that does
# place files from it records it, exactly as before.
test_upgrade_copy_mode_records_the_source_it_placed_from() {
  fixture_jig_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  src=$(cd "$src" && pwd) # $TMPDIR can end in a slash; the manifest records a clean path
  _mk_source_v2 "$src"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "manifest updated"
  assert_file_contains .ai/manifest "jig.source: $src"
  assert_file_contains .ai/manifest "jig.version: 9.9.9"

  rm -rf "$src"
}

# Reported 2026-09-23: an upgrade in a project installed in copy mode ended in
# `.ai/scripts/jig: line 112: key: No such file or directory`, a line the
# dispatcher it had just replaced does not contain. `cp` onto the destination
# rewrites it in place, keeping the inode, and the destination here is the very
# script bash is executing: once the file grew, bash read on from the offset it
# had reached and ran whatever the *new* bytes said there. The new dispatcher
# below is the installed one plus a trailing block, so a shell that reads past
# the end of the file it started lands exactly on it and says so.
test_upgrade_copy_mode_replaces_the_running_dispatcher_without_running_its_tail() {
  fixture_jig_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  src=$(cd "$src" && pwd)
  _mk_source_v2 "$src"
  _unbump_source "$src"
  cat >> "$src/scripts/jig" <<'EOF'

printf 'TAIL-EXECUTED\n'
exit 42
EOF
  fixture_release_source "$src"

  run jig_installed upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "TAIL-EXECUTED"
  assert_contains "$OUT" "replace .ai/scripts/jig"

  rm -rf "$src"
}

# --- orphan deletion is scoped to `.ai/` and adapter skills dirs (_upgrade_deletable) ---

# The ordinary case the decision table above only exercises inside `.ai/`:
# a file this framework installed under an adapter's skills directory, later
# removed from the source, is still deleted once orphaned.
test_upgrade_deletes_orphaned_skill_under_claude_skills_dir() {
  fixture_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-orphan.XXXXXX")
  cp -R "$JIG_HOME"/. "$src"/
  fixture_release_source "$src"
  mkdir -p "$src/skills/jig-orphantest"
  cat > "$src/skills/jig-orphantest/SKILL.md" <<'EOF'
---
name: jig-orphantest
description: fixture skill removed again in the next source
---
# jig-orphantest
EOF
  # Released again: a source with local changes is no release.
  fixture_release_source "$src"
  jig init --from "$src" >/dev/null
  assert_file .claude/skills/jig-orphantest/SKILL.md

  rm -rf "$src/skills/jig-orphantest"
  fixture_release_source "$src"
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "delete .claude/skills/jig-orphantest/SKILL.md"
  assert_no_file .claude/skills/jig-orphantest/SKILL.md

  rm -rf "$src"
}

# A manifest entry outside `.ai/` and every adapter's skills directory is not
# proof the framework may delete it there — only that some earlier version of
# this file wrote the line. Kept, and reported `keep-outside`, not `delete`
# (scripts/lib/upgrade.sh, _upgrade_deletable).
test_upgrade_keeps_manifest_entry_outside_delete_roots() {
  fixture_jig_repo

  mkdir -p docs
  printf 'not framework-owned\n' > docs/x.md
  local hash
  hash=$(git hash-object docs/x.md)
  printf '%s docs/x.md\n' "$hash" >> .ai/manifest

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "keep-outside docs/x.md"
  assert_not_contains "$OUT" "delete docs/x.md"
  assert_file docs/x.md
  assert_file_contains docs/x.md "not framework-owned"
  assert_file_contains .ai/manifest "docs/x.md"
}

# A `..` component makes a manifest path untrustworthy on its own terms,
# regardless of where it points — refused the same way even without a real
# file behind it (a project's manifest is not proof of what a path is).
test_upgrade_keeps_manifest_entry_with_path_traversal() {
  fixture_jig_repo

  printf '%s\n' "0000000000000000000000000000000000000000 ../x" >> .ai/manifest

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "keep-outside ../x"
  assert_not_contains "$OUT" "delete ../x"
  assert_file_contains .ai/manifest "../x"
}

# The staged tree cmd_upgrade builds is derived from the *current*
# .ai/config.yaml, so activating a profile after init and re-running
# `jig upgrade` (copy mode) must install it — not just pick up drift in
# already-tracked files (domains/install).
test_upgrade_copy_mode_installs_newly_activated_profile() {
  fixture_repo
  jig init --from "$JIG_HOME" --profiles generic >/dev/null
  assert_no_file .ai/profiles/shell
  cat > .ai/config.yaml <<'EOF'
profiles: [generic, shell]
adapters: [claude, codex]
EOF

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "install .ai/profiles/shell/profile.yaml"
  assert_contains "$OUT" "install .ai/profiles/shell/verify.sh"

  assert_file .ai/profiles/shell/profile.yaml
  assert_file .ai/profiles/shell/verify.sh

  local want got
  want=$(git -C "$JIG_HOME" hash-object profiles/shell/verify.sh)
  got=$(sed -n 's/^\(.*\) \.ai\/profiles\/shell\/verify\.sh$/\1/p' .ai/manifest)
  assert_eq "$want" "$got"

  # Upgrade installed the profile; give its smoke run an applicable check.
  # Without this runner the result depends on whether the host has shellcheck:
  # a profile that skips every check correctly returns 3, not a false pass.
  mkdir -p tests
  cat > tests/run.sh <<'EOF'
#!/usr/bin/env sh
test -f .ai/profiles/shell/verify.sh
EOF
  chmod +x tests/run.sh
  run jig verify --profile shell
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "shell: tests (tests/run.sh): pass"
  assert_contains "$OUT" "RESULT shell: pass"
}

# --- path traversal in config-driven profile/adapter names -----------------
# `jig upgrade` never takes --profile/--profiles flags; the only way a bad
# name reaches it is through .ai/config.yaml, in both copy and link mode.

test_upgrade_copy_mode_rejects_config_path_traversal_profile() {
  fixture_repo
  jig init --from "$JIG_HOME" --profiles generic >/dev/null
  cat > .ai/config.yaml <<'EOF'
profiles: [.., generic]
adapters: [claude, codex]
EOF

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "invalid profile name"
  assert_no_file .ai/docs
  assert_no_file .ai/tests
}

test_upgrade_link_mode_rejects_config_path_traversal_profile() {
  skip_unless_symlinks
  fixture_repo
  jig init --from "$JIG_HOME" --link --profiles generic >/dev/null
  cat > .ai/config.yaml <<'EOF'
profiles: [.., generic]
adapters: [claude, codex]
EOF

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "invalid profile name"
  assert_no_file .ai/docs
  assert_no_file .ai/tests
}

test_upgrade_copy_mode_rejects_config_path_traversal_adapter() {
  fixture_repo
  jig init --from "$JIG_HOME" --profiles generic >/dev/null
  cat > .ai/config.yaml <<'EOF'
profiles: [generic]
adapters: [.., claude]
EOF

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "invalid adapter name"
}

test_upgrade_propagates_changed_knowledge_template() {
  fixture_jig_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2 "$src"
  printf '\n<!-- v2 template marker -->\n' >> "$src/templates/knowledge/feature.md"
  fixture_release_source "$src"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "replace .ai/templates/knowledge/feature.md"
  assert_file_contains .ai/templates/knowledge/feature.md "v2 template marker"

  rm -rf "$src"
}

# --- spec templates: an install that predates them --------------------------
# Simulates a project initialised before `.ai/templates/spec/` existed: the
# installed copy and its manifest entries are removed by hand, the way a
# frozen/older install would look, then `jig upgrade` must pick it back up
# (mirrors test_upgrade_copy_mode_installs_newly_activated_profile).

test_upgrade_dry_run_reports_missing_spec_templates_as_pending() {
  fixture_jig_repo
  rm -rf .ai/templates/spec
  grep -v '\.ai/templates/spec/' .ai/manifest > .ai/manifest.tmp
  mv .ai/manifest.tmp .ai/manifest

  run jig upgrade --from "$JIG_HOME" --dry-run
  assert_eq 0 "$RC"
  assert_contains "$OUT" "install .ai/templates/spec/spec.md"
  assert_contains "$OUT" "install .ai/templates/spec/roadmap.md"
  assert_no_file .ai/templates/spec/spec.md
}

test_upgrade_installs_spec_templates_for_a_pre_spec_install_copy_mode() {
  fixture_jig_repo
  rm -rf .ai/templates/spec
  grep -v '\.ai/templates/spec/' .ai/manifest > .ai/manifest.tmp
  mv .ai/manifest.tmp .ai/manifest

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "install .ai/templates/spec/spec.md"
  assert_contains "$OUT" "install .ai/templates/spec/roadmap.md"
  assert_file .ai/templates/spec/spec.md
  assert_file .ai/templates/spec/roadmap.md
  assert_file_contains .ai/manifest ".ai/templates/spec/spec.md"
  assert_file_contains .ai/manifest ".ai/templates/spec/roadmap.md"

  # An upgrade is a unit of work (adr-20260930-an-upgrade-is-a-unit-of-work):
  # it left this checkout on its own branch, with the change staged, not on
  # main. Commit and merge it back, the way its own "next" line says to, so
  # main is clean again — spec new now finds the reinstalled template on its
  # own, no --from needed.
  local branch
  branch=$(git symbolic-ref --short HEAD)
  git commit -q -F .ai/runtime/upgrade/message
  git checkout -q main
  git merge -q --ff-only "$branch"
  run jig spec new idea-x
  assert_eq 0 "$RC"
}

test_upgrade_link_mode_links_spec_templates_for_a_pre_spec_install() {
  skip_unless_symlinks
  fixture_repo
  jig init --from "$JIG_HOME" --link >/dev/null
  rm -f .ai/templates/spec

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "link .ai/templates/spec"
  assert_symlink .ai/templates/spec
  assert_file .ai/templates/spec/spec.md
  assert_file .ai/templates/spec/roadmap.md
}

test_upgrade_missing_from_falls_back_to_manifest_source() {
  fixture_jig_repo
  # from inside the installed copy's own tree, jig_source_root cannot find a
  # source checkout, so upgrade must fall back to the manifest's jig.source.
  run jig_installed upgrade
  assert_eq 0 "$RC"
}

# Regression for `upgrade_pending` (stale-install-check task): `status` and
# `verify` treat an unresolvable source root as "unknown, skip the check"
# (see tests/status.t.sh, tests/verify.t.sh), but that graceful degradation
# lives entirely in upgrade_pending — a direct `jig upgrade` with no --from
# and a deleted source checkout must still die exactly as before.
test_upgrade_still_dies_without_from_when_source_root_gone() {
  fixture_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-del.XXXXXX")
  cp -R "$JIG_HOME"/. "$src"/
  fixture_release_source "$src"
  jig init --from "$src" >/dev/null
  rm -rf "$src"

  # No global jig either: with one, upgrade_source reads from it.
  run jig_installed_without_global upgrade
  assert_eq 1 "$RC"
  assert_contains "$OUT" "cannot determine the framework source root"
}

# --- the global framework as a source -------------------------------------------
# (adr-20261029-the-manifest-names-the-global-framework-not-its-path)

# _upgrade_global_path <framework-dir> — a PATH whose only `jig` is
# <framework-dir>/scripts/jig, the way install.sh places it: a symlink in a bin
# directory, or that scripts/ directory itself where `ln -s` cannot link
# (jig_global_executable only recognises a path ending in /scripts/jig).
_upgrade_global_path() {
  local root="$1" bin
  bin=$(mktemp -d "${TMPDIR:-/tmp}/jig-global-bin.XXXXXX")
  if ln -s "$root/scripts/jig" "$bin/jig" 2>/dev/null && [ -L "$bin/jig" ]; then
    path_without_jig "$bin"
  else
    path_without_jig "$root/scripts"
  fi
}

# _upgrade_foreign_manifest — record another machine's install path as the
# source, the way a colleague's committed upgrade leaves it (jig-ui,
# 2026-10-29), and commit it.
_upgrade_foreign_manifest() {
  sed 's|^jig.source:.*|jig.source: /nonexistent/someone-else/.local/share/jig|' \
    .ai/manifest > .ai/manifest.tmp
  mv .ai/manifest.tmp .ai/manifest
  git add .ai/manifest
  git commit -q -m "manifest from another machine"
}

# The reported case: the manifest names a path that does not exist here, and
# the project's own copy refused to upgrade although `jig status` had just
# found the global jig and offered the upgrade.
test_upgrade_reads_from_the_global_jig_when_the_recorded_source_is_not_here() {
  _unit_project
  _upgrade_foreign_manifest
  local global path
  global=$(_unit_source)
  _unbump_source "$global" # same version: the project's copy does the work itself
  global=$(cd "$global" && pwd -P)
  path=$(_upgrade_global_path "$global")

  run env PATH="$path" .ai/scripts/jig upgrade --dry-run
  assert_eq 0 "$RC"
  assert_contains "$OUT" "install .claude/skills/jig-newthing/SKILL.md"
  assert_not_contains "$OUT" "/nonexistent"

  run env PATH="$path" .ai/scripts/jig upgrade
  assert_eq 0 "$RC"
  assert_contains "$OUT" "manifest updated"
  assert_file .claude/skills/jig-newthing/SKILL.md
  # The foreign path is replaced, and not by this machine's path either.
  assert_file_contains .ai/manifest "jig.source: global"
  assert_not_contains "$(cat .ai/manifest)" "/nonexistent"
  assert_not_contains "$(cat .ai/manifest)" "$global"

  rm -rf "$global"
}

# Nothing to read from: the refusal says where it looked and names no path the
# manifest records — on this machine that path means nothing.
test_upgrade_without_any_source_names_where_it_looked_not_the_foreign_path() {
  _unit_project
  _upgrade_foreign_manifest

  run jig_installed_without_global upgrade
  assert_eq 1 "$RC"
  assert_contains "$OUT" "cannot determine the framework source root"
  assert_contains "$OUT" "no global jig is on PATH"
  assert_contains "$OUT" "pass --from <dir>"
  assert_not_contains "$OUT" "/nonexistent"
}

# An older global jig is no stand-in for a recorded source that is not here:
# reading from it would plan a downgrade, and `status`/`verify` would count it
# as pending and ask for it. Pending stays unknown, as it was, and the refusal
# names the way forward.
test_upgrade_does_not_fall_back_to_an_older_global_jig() {
  _unit_project
  _upgrade_foreign_manifest
  local global path
  global=$(_unit_source)
  sed 's/^JIG_VERSION=.*/JIG_VERSION="0.0.1"/' "$global/scripts/lib/version.sh" > "$global/v.tmp"
  mv "$global/v.tmp" "$global/scripts/lib/version.sh"
  global=$(cd "$global" && pwd -P)
  path=$(_upgrade_global_path "$global")

  run env PATH="$path" .ai/scripts/jig upgrade --dry-run
  assert_eq 1 "$RC"
  assert_contains "$OUT" "older than this project"
  assert_contains "$OUT" "jig self-update"
  assert_not_contains "$OUT" "/nonexistent"

  run env PATH="$path" .ai/scripts/jig status
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "pending"

  rm -rf "$global"
}

# The rule holds for unreleased code too: a project on `X.Y.Z+<sha>` is newer
# than a released global jig at an older version, so that global is no stand-in
# for its recorded source either.
test_upgrade_does_not_fall_back_to_an_older_global_for_unreleased_code() {
  _unit_project
  local src global path
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-unrel.XXXXXX")
  src=$(cd "$src" && pwd)
  fixture_unreleased_source "$src"
  run jig upgrade --from "$src" --unreleased
  assert_eq 0 "$RC"
  assert_file_contains .ai/manifest "jig.version: $(_unreleased_declared)+"
  git add -A
  git commit -q -m "took unreleased code"
  _upgrade_foreign_manifest

  global=$(_unit_source)
  sed 's/^JIG_VERSION=.*/JIG_VERSION="0.0.1"/' "$global/scripts/lib/version.sh" > "$global/v.tmp"
  mv "$global/v.tmp" "$global/scripts/lib/version.sh"
  global=$(cd "$global" && pwd -P)
  path=$(_upgrade_global_path "$global")

  run env PATH="$path" .ai/scripts/jig upgrade --dry-run
  assert_eq 1 "$RC"
  assert_contains "$OUT" "older than this project"
  assert_contains "$OUT" "jig self-update"

  rm -rf "$global" "$src"
}

# The same rule when the manifest records `global`: on a colleague's machine
# with an older global jig, `global` is that older checkout, and it must not
# be read from either.
test_upgrade_does_not_read_a_recorded_global_that_is_older() {
  _unit_project
  sed 's|^jig.source:.*|jig.source: global|' .ai/manifest > .ai/manifest.tmp
  mv .ai/manifest.tmp .ai/manifest
  git add .ai/manifest
  git commit -q -m "manifest names the global framework"
  local global path
  global=$(_unit_source)
  sed 's/^JIG_VERSION=.*/JIG_VERSION="0.0.1"/' "$global/scripts/lib/version.sh" > "$global/v.tmp"
  mv "$global/v.tmp" "$global/scripts/lib/version.sh"
  global=$(cd "$global" && pwd -P)
  path=$(_upgrade_global_path "$global")

  run env PATH="$path" .ai/scripts/jig upgrade --dry-run
  assert_eq 1 "$RC"
  assert_contains "$OUT" "older than this project"
  assert_contains "$OUT" "jig self-update"

  run env PATH="$path" .ai/scripts/jig status
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "pending"

  rm -rf "$global"
}

# `global` names the global framework of whichever machine reads it: written
# when the source is the global jig, read back as this machine's.
test_init_from_the_global_jig_records_global_and_upgrade_reads_it() {
  fixture_repo
  local global path
  global=$(mktemp -d "${TMPDIR:-/tmp}/jig-global-src.XXXXXX")
  cp -R "$JIG_HOME"/. "$global"/
  fixture_release_source "$global"
  global=$(cd "$global" && pwd -P)
  path=$(_upgrade_global_path "$global")

  run env PATH="$path" "$global/scripts/jig" init
  assert_eq 0 "$RC"
  assert_file_contains .ai/manifest "jig.source: global"
  assert_not_contains "$(cat .ai/manifest)" "$global"

  run env PATH="$path" .ai/scripts/jig upgrade --dry-run
  assert_eq 0 "$RC"
  assert_contains "$OUT" "manifest unchanged (dry run)"

  # On a machine without a global jig, `global` names nothing: the same
  # refusal as a missing path, never a crash.
  run jig_installed_without_global upgrade --dry-run
  assert_eq 1 "$RC"
  assert_contains "$OUT" "cannot determine the framework source root"

  rm -rf "$global"
}

# New shared guidance must ship through real skills in both adapters/modes.
_sdd_assert_reference_links() {
  local runtime
  for runtime in .claude .codex; do
    assert_file "$runtime/skills/jig-task/references/requirements-and-planning.md"
    assert_file "$runtime/skills/jig-task/references/handoff.md"
    assert_file "$runtime/skills/jig-task/references/ui-states.md"
    assert_file "$runtime/skills/jig-task/references/show-the-document.md"
    assert_file "$runtime/skills/jig-accept/../jig-task/references/show-the-document.md"
    assert_file "$runtime/skills/jig-analyze/references/ambiguity.md"
    assert_file "$runtime/skills/jig-review/references/change-scope.md"
    assert_file "$runtime/skills/jig-review/../jig-task/references/ui-states.md"
    assert_file "$runtime/skills/jig-implement/../jig-review/references/change-scope.md"
  done
}

test_sdd_upgrade_adds_references_and_preserves_modified_consumers() {
  fixture_repo
  local old_source="$PWD/old-source" dir
  mkdir "$old_source"
  for dir in scripts skills templates adapters profiles; do
    cp -R "$JIG_HOME/$dir" "$old_source/$dir"
  done
  rm "$old_source/skills/jig-task/references/requirements-and-planning.md" \
    "$old_source/skills/jig-task/references/handoff.md" \
    "$old_source/skills/jig-task/references/ui-states.md" \
    "$old_source/skills/jig-task/references/show-the-document.md" \
    "$old_source/skills/jig-analyze/references/ambiguity.md" \
    "$old_source/skills/jig-review/references/change-scope.md"
  fixture_release_source "$old_source"
  jig init --from "$old_source" >/dev/null
  echo 'User-owned review instruction' >> .codex/skills/jig-review/SKILL.md
  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  _sdd_assert_reference_links
  assert_file_contains .codex/skills/jig-review/SKILL.md 'User-owned review instruction'
  assert_file_contains .ai/manifest '.codex/skills/jig-task/references/ui-states.md'
}

test_sdd_upgrade_link_mode_exposes_references_in_both_adapters() {
  skip_unless_symlinks
  fixture_repo
  jig init --from "$JIG_HOME" --link >/dev/null
  rm .codex/skills/jig-task
  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_symlink .codex/skills/jig-task
  _sdd_assert_reference_links
}

# --- the marked instructions section ------------------------------------------
# adr-20260924-jig-owns-a-marked-section-of-the-instructions. The same three
# outcomes as any other framework-owned path — replace, keep-modified,
# install — applied to the region between the markers instead of to a file.

# _mk_source_v2_section <dest> — source-v2 whose Jig section differs, which is
# the only thing that makes an upgrade of the section non-trivial.
_mk_source_v2_section() {
  local dest="$1" tmp
  _mk_source_v2 "$dest"
  tmp="$dest/templates/AGENTS.md.tmp"
  sed 's/^## Workflow$/## Workflow\n\nA brand new sentence from source-v2./' \
    "$dest/templates/AGENTS.md" > "$tmp"
  mv "$tmp" "$dest/templates/AGENTS.md"
  # Released again: a source with local changes is no release.
  fixture_release_source "$dest"
}

test_upgrade_replaces_the_marked_instructions_section() {
  fixture_jig_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2_section "$src"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "replace AGENTS.md (Jig section)"
  assert_file_contains AGENTS.md "A brand new sentence from source-v2."
  # Everything outside the markers is the project's and must not move.
  assert_file_contains AGENTS.md "## Working rules"
  assert_file_contains .ai/manifest "instructions.section: "
}

test_upgrade_keeps_a_modified_instructions_section() {
  fixture_jig_repo
  local src before
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2_section "$src"

  # A human edits inside the markers: from here the section is theirs.
  sed 's/^## Read first$/## Read first (our version)/' AGENTS.md > AGENTS.md.new
  mv AGENTS.md.new AGENTS.md
  before=$(cat AGENTS.md)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "keep-modified AGENTS.md (Jig section)"
  assert_not_contains "$OUT" "replace AGENTS.md"
  assert_eq "$before" "$(cat AGENTS.md)"
}

test_upgrade_keeps_a_section_whose_markers_were_removed() {
  fixture_jig_repo
  local src before
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2_section "$src"

  grep -v 'jig:begin\|jig:end' AGENTS.md > AGENTS.md.new
  mv AGENTS.md.new AGENTS.md
  before=$(cat AGENTS.md)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  # Removed on purpose stays removed, exactly as ADR-0024 concluded for a
  # deleted session-hook line.
  assert_contains "$OUT" "keep-modified AGENTS.md (Jig section)"
  assert_eq "$before" "$(cat AGENTS.md)"
}

test_upgrade_reports_an_unmarked_agents_md_and_writes_nothing() {
  fixture_repo
  printf '# Our own rules\n\nUse tabs.\n' > AGENTS.md
  jig init --from "$JIG_HOME" >/dev/null
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2_section "$src"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "keep-unmarked AGENTS.md"
  assert_eq "# Our own rules

Use tabs." "$(cat AGENTS.md)"
  assert_not_contains "$(cat .ai/manifest)" "instructions.section"
}

test_upgrade_reports_a_malformed_marker_pair() {
  fixture_jig_repo
  local src before
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2_section "$src"

  # A second begin marker: jig cannot tell which region is its own, so it
  # refuses rather than guessing.
  printf '<!-- jig:begin -->\n' >> AGENTS.md
  before=$(cat AGENTS.md)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "keep-malformed AGENTS.md (Jig section)"
  assert_eq "$before" "$(cat AGENTS.md)"
}

test_upgrade_reports_conflict_for_markers_it_did_not_write() {
  fixture_repo
  printf '# Our own rules\n' > AGENTS.md
  jig init --from "$JIG_HOME" >/dev/null
  local src before
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2_section "$src"

  # Markers appear after init recorded nothing: jig never wrote this, so it
  # does not adopt it behind the human's back.
  printf '<!-- jig:begin -->\nsomething\n<!-- jig:end -->\n' >> AGENTS.md
  before=$(cat AGENTS.md)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "keep-conflict AGENTS.md (Jig section)"
  assert_eq "$before" "$(cat AGENTS.md)"
}

test_upgrade_dry_run_leaves_the_section_alone() {
  fixture_jig_repo
  local src before
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2_section "$src"
  before=$(cat AGENTS.md)

  run jig upgrade --from "$src" --dry-run
  assert_eq 0 "$RC"
  assert_contains "$OUT" "replace AGENTS.md (Jig section)"
  assert_eq "$before" "$(cat AGENTS.md)"
}

# A section update is pending work like any other, so `jig status` counts it
# and `jig verify` refuses a stale install because of it — which is why the
# report reuses the verb `replace` instead of inventing one.
test_upgrade_pending_includes_a_section_replace() {
  fixture_jig_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2_section "$src"

  run jig upgrade --from "$src" --dry-run
  assert_contains "$(printf '%s\n' "$OUT" | grep -E '^(install|link|replace) ')" \
    "replace AGENTS.md (Jig section)"
}

# And a project that keeps its own instructions is never blocked by that
# choice: keep-unmarked is deliberately outside the pending filter.
test_upgrade_pending_excludes_an_unmarked_section() {
  fixture_repo
  printf '# Our own rules\n' > AGENTS.md
  jig init --from "$JIG_HOME" >/dev/null

  run jig upgrade --from "$JIG_HOME" --dry-run
  assert_contains "$OUT" "keep-unmarked AGENTS.md"
  assert_eq "" "$(printf '%s\n' "$OUT" | grep -E '^(install|link|replace) ' || true)"
}

test_upgrade_installs_the_instructions_template_for_an_older_install() {
  fixture_jig_repo
  # An install made before the template was framework-owned.
  rm -f .ai/templates/AGENTS.md
  grep -v ' \.ai/templates/AGENTS\.md$' .ai/manifest > .ai/manifest.new
  mv .ai/manifest.new .ai/manifest

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "install .ai/templates/AGENTS.md"
  assert_file .ai/templates/AGENTS.md
}

# Link mode decides the section exactly as copy mode does — the record it rests
# on is a manifest header key, and link mode writes a header too. design.md §13
# asked for this explicitly, because "same function, both branches" is an
# argument, not evidence.
test_upgrade_link_mode_replaces_the_marked_instructions_section() {
  skip_unless_symlinks
  fixture_repo
  local src tmp
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-srclink.XXXXXX")
  cp -R "$JIG_HOME"/. "$src"/
  fixture_release_source "$src"
  jig init --link --from "$src" >/dev/null
  assert_file_contains .ai/manifest "instructions.section: "

  tmp="$src/templates/AGENTS.md.tmp"
  sed 's/^## Workflow$/## Workflow\n\nA brand new sentence from source-v2./' \
    "$src/templates/AGENTS.md" > "$tmp"
  mv "$tmp" "$src/templates/AGENTS.md"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "replace AGENTS.md (Jig section)"
  assert_file_contains AGENTS.md "A brand new sentence from source-v2."
  assert_file_contains AGENTS.md "## Working rules"
}

# --- what the project's own config.yaml does not mention ----------------------

test_upgrade_names_config_keys_the_project_file_does_not_mention() {
  fixture_jig_repo
  grep -v 'verify.full_run' .ai/config.yaml > .ai/config.yaml.tmp
  mv .ai/config.yaml.tmp .ai/config.yaml
  local before
  before=$(cat .ai/config.yaml)

  run jig upgrade
  assert_eq 0 "$RC"
  assert_contains "$OUT" ".ai/config.yaml does not mention 1 key(s) this version reads, each on its default: verify.full_run"
  # shellcheck disable=SC2016  # a literal backticked command name
  assert_contains "$OUT" 'hint: `jig config keys` lists them'
  # The whole point: an upgrade says what changed underneath and changes
  # nothing in the team's file (ADR-0024).
  assert_eq "$before" "$(cat .ai/config.yaml)" "upgrade touched .ai/config.yaml"
}

test_upgrade_says_nothing_about_config_keys_when_the_file_mentions_them_all() {
  fixture_jig_repo
  run jig upgrade
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "does not mention"
}

test_upgrade_dry_run_says_nothing_about_config_keys() {
  fixture_jig_repo
  grep -v 'verify.full_run' .ai/config.yaml > .ai/config.yaml.tmp
  mv .ai/config.yaml.tmp .ai/config.yaml

  run jig upgrade --dry-run
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "does not mention"
}

# --- an interrupted run, and the two sides of the hash comparison ------------

# Reproduces the reported case (external review M8, reproduced twice): files
# are placed one at a time and the manifest is written once at the end, so an
# interruption leaves the new bytes on disk against the recorded old hash.
# Until the decision table compared the disk with the stage, the repeat read
# every file the interrupted run had placed as one the user had edited and
# said so for ever — `keep-modified` on every later run, permanent drift in
# `jig status`, and an install that never finished.
#
# The interruption is a real one: the destination directory of a file the new
# source changes cannot be written, so the run dies inside the placement loop
# with earlier paths already placed.
test_upgrade_finishes_a_run_interrupted_midway() {
  skip_unless_readonly_dirs
  fixture_jig_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2 "$src"
  # Sorts after .ai/** and .claude/**, so those are placed before the run dies.
  printf '\n# v2 marker\n' >> "$src/skills/jig-verify/SKILL.md"
  fixture_release_source "$src"

  chmod 500 .codex/skills/jig-verify
  run jig upgrade --from "$src"
  chmod 700 .codex/skills/jig-verify
  assert_eq 1 "$RC"
  assert_contains "$OUT" "could not write"
  # The state an interruption leaves: placed on disk, old hash in the manifest.
  assert_file_contains .ai/profiles/generic/verify.sh "v2 marker"
  local placed_hash
  placed_hash=$(git hash-object --no-filters .ai/profiles/generic/verify.sh)
  assert_not_contains "$(cat .ai/manifest)" "$placed_hash"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "already-placed .ai/profiles/generic/verify.sh"
  assert_not_contains "$OUT" "keep-modified .ai/profiles/generic/verify.sh"
  assert_contains "$OUT" "replace .codex/skills/jig-verify/SKILL.md"
  assert_contains "$OUT" "manifest updated"

  # Once reconciled it stays reconciled, and says nothing more about it.
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "already-placed"
  assert_not_contains "$OUT" "keep-modified .ai/profiles/generic/verify.sh"

  # The drift the bug produced: files jig itself had placed, reported for ever
  # as ones somebody edited. (`pending` is not asserted here: this fixture's
  # status measures the install against $JIG_HOME, not against $src.)
  run jig status
  assert_contains "$OUT" "drift: 0 modified, 0 missing"

  run jig upgrade --from "$src" --dry-run
  assert_not_contains "$OUT" "keep-modified"
  assert_not_contains "$OUT" "replace .ai/profiles/generic/verify.sh"

  rm -rf "$src"
}

# The other half of the same interruption, and the one the reported case hit:
# a path the new version installs for the first time. Placed but not yet in the
# manifest, it used to read as `keep-conflict` — somebody else's file at a
# framework path — which no later run ever revisits, so the path never became
# framework-owned and was never updated again.
test_upgrade_adopts_a_path_an_interrupted_run_installed() {
  skip_unless_readonly_dirs
  fixture_jig_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2 "$src"
  printf '\n# v2 marker\n' >> "$src/skills/jig-verify/SKILL.md"
  fixture_release_source "$src"

  chmod 500 .codex/skills/jig-verify
  run jig upgrade --from "$src"
  chmod 700 .codex/skills/jig-verify
  assert_eq 1 "$RC"
  # jig-newthing is new in source-v2 and sorts before jig-verify, so the
  # interrupted run installed it and never recorded it.
  assert_file .claude/skills/jig-newthing/SKILL.md
  assert_not_contains "$(cat .ai/manifest)" ".claude/skills/jig-newthing/SKILL.md"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "already-placed .claude/skills/jig-newthing/SKILL.md"
  assert_not_contains "$OUT" "keep-conflict .claude/skills/jig-newthing/SKILL.md"
  assert_file_contains .ai/manifest ".claude/skills/jig-newthing/SKILL.md"

  rm -rf "$src"
}

# The second way the same `keep-modified` state is reached, with no
# interruption at all: `git hash-object` applies the repository's clean filters
# to a path inside it, while the staging tree in $TMPDIR is outside any
# repository and is hashed as it stands. The two sides of the comparison were
# computed differently, so a filtered framework path was replaced on every run
# and then read as modified for ever.
test_upgrade_hashes_both_sides_alike_under_clean_filters() {
  fixture_repo
  printf '.ai/profiles/** filter=jigtest\n' > .gitattributes
  git config filter.jigtest.clean 'sed "s/^/# /"'
  git add .gitattributes
  git commit -q -m "clean filter over the framework's profiles"
  jig init --from "$JIG_HOME" >/dev/null
  # init appends to the tracked .gitattributes; an upgrade starts from a
  # committed tree.
  git add -A && git commit -q -m "jig init"

  # The filter has to bite, or this test proves nothing.
  local filtered raw
  filtered=$(git hash-object .ai/profiles/generic/verify.sh)
  raw=$(git hash-object --no-filters .ai/profiles/generic/verify.sh)
  [ "$filtered" != "$raw" ] || skip "clean filters do not change hashes here"

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "replace .ai/profiles/"
  assert_not_contains "$OUT" "keep-modified .ai/profiles/"

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "keep-modified .ai/profiles/"

  run jig status
  assert_contains "$OUT" "drift: 0 modified, 0 missing, 0 pending"
}

# The same divergence by its other mechanism, and the one --no-filters does not
# answer: the object format. In a SHA-256 repository the project's files hash to
# 64 hex digits and a staging tree outside it to 40, so every framework path
# compared unequal — the first run replaced all of them and wrote SHA-1 hashes
# into a SHA-256 manifest, and from the second run on the whole install read as
# modified and never updated again.
test_upgrade_hashes_both_sides_alike_in_a_sha256_repository() {
  skip_unless_sha256_repos
  git init -q --object-format=sha256 .
  git symbolic-ref HEAD refs/heads/main
  printf '# fixture\n' > README.md
  git add README.md
  git commit -q -m init
  jig init --from "$JIG_HOME" >/dev/null

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "0 placed"
  assert_not_contains "$OUT" "replace .ai/scripts/"

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "keep-modified .ai/scripts/"

  run jig status
  assert_contains "$OUT" "drift: 0 modified, 0 missing, 0 pending"
}

# The run asks the install it just made whether anything is still missing, and
# names it (finding F1, from a live case: a run printed "55 placed, 49 kept,
# 2 removed; manifest updated" and left .ai/templates/AGENTS.md unplaced, found
# a day later in `jig doctor` as "1 pending item(s) although the version is the
# same").
#
# The check has to be the newly installed dispatcher, as a subprocess, and this
# test is the reason: an upgrade is carried out by the code of the version being
# replaced, and that code stages only what it knows about. Here the source
# stages one path this running code does not, exactly as 0.16.0 staged
# .ai/templates/AGENTS.md and 0.15.1 did not. Asking upgrade_pending in this
# process would ask the old decision table, which is satisfied by construction
# and would stay silent.
test_upgrade_names_what_is_still_not_installed() {
  fixture_jig_repo

  # A complete run says nothing about leftovers.
  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "still not installed"

  local src anchor
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-next.XXXXXX")
  _mk_source_v2 "$src"
  _unbump_source "$src"
  # The literal source line, $source and all: it is grepped for, not evaluated.
  # shellcheck disable=SC2016
  anchor='cp -p "$source/templates/AGENTS.md" "$stage/.ai/templates/AGENTS.md"'
  grep -qF "$anchor" "$src/scripts/lib/upgrade.sh" \
    || fail "the staging line this test patches is gone; rewrite the test"
  # The next version stages one more path than the running code does.
  awk -v anchor="$anchor" '
    { print }
    index($0, anchor) { print "  cp -p \"$source/templates/AGENTS.md\" \"$stage/.ai/templates/NEWTHING.md\"" }
  ' "$src/scripts/lib/upgrade.sh" > "$src/scripts/lib/upgrade.sh.tmp"
  mv "$src/scripts/lib/upgrade.sh.tmp" "$src/scripts/lib/upgrade.sh"
  fixture_release_source "$src"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_no_file .ai/templates/NEWTHING.md
  assert_contains "$OUT" "1 item(s) still not installed"
  # Indented: quoted from another run, and not to be mistaken for this run's
  # own report lines by a reader or by anything reading line starts.
  assert_contains "$OUT" "  install .ai/templates/NEWTHING.md"
  assert_contains "$OUT" "not committed, because the install is not complete"

  # And the run the message asks for finishes the job — done by the project's
  # own dispatcher, which is now the newer code, the way the check itself asked
  # that code whether anything was left.
  run jig_installed upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_file .ai/templates/NEWTHING.md
  assert_not_contains "$OUT" "still not installed"

  rm -rf "$src"
}

# The marked section's record lives in the manifest header, which is written at
# the end of the run, so an interruption leaves it with the same hole a file has:
# the region already holds the source's text while the header still records the
# older hash. Read as an edit, it would never be replaced again.
#
# The interruption is constructed rather than provoked, because the section is
# written at one fixed point near the end of the run: the manifest is put back
# to what it was before, which is exactly the state a run interrupted after
# writing the section and before writing the manifest leaves behind.
test_upgrade_reconciles_a_section_an_interrupted_run_had_written() {
  fixture_jig_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2_section "$src"
  cp .ai/manifest manifest.before.tmp

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "replace AGENTS.md (Jig section)"
  assert_file_contains AGENTS.md "A brand new sentence from source-v2."

  # The manifest write is undone: the section is the source's, the record is old.
  cp manifest.before.tmp .ai/manifest

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "already-placed AGENTS.md (Jig section)"
  assert_not_contains "$OUT" "keep-modified AGENTS.md (Jig section)"
  assert_contains "$OUT" "manifest updated"
  # And it stuck: a third run has nothing left to say about the section.
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "already-placed AGENTS.md (Jig section)"
  assert_not_contains "$OUT" "keep-modified AGENTS.md (Jig section)"

  rm -rf "$src"
}

# A reconciliation is the one outcome that changes the manifest while writing no
# file, so it has to count as applied: `_upgrade_records_source` otherwise
# refuses the write, and a repeat of a run interrupted after its *last*
# placement would find every path already placed, write nothing, report
# `manifest unchanged` and stay stuck — the defect, reached by the fix.
#
# Every other already-placed test also has a genuine `replace` in the same run,
# which satisfies that count on its own; this one isolates the term. The source
# passed is deliberately not the recorded one, which is when the count decides.
test_upgrade_writes_the_manifest_for_a_reconciliation_alone() {
  fixture_jig_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src2.XXXXXX")
  _mk_source_v2 "$src"
  cp .ai/manifest manifest.before.tmp

  # A complete run: after it, nothing is left to place from $src.
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "replace .ai/profiles/generic/verify.sh"

  # Undo only the manifest write, leaving the files of the run in place.
  cp manifest.before.tmp .ai/manifest

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "0 placed"
  assert_contains "$OUT" "already-placed .ai/profiles/generic/verify.sh"
  assert_contains "$OUT" "manifest updated"
  assert_file_contains .ai/manifest "jig.version: 9.9.9"

  # Nothing is left over: the next run is quiet and the install is not adrift.
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "already-placed"
  assert_not_contains "$OUT" "keep-modified"
  run jig status
  assert_contains "$OUT" "drift: 0 modified, 0 missing"

  rm -rf "$src"
}

# Link mode keeps the same record in the same header, so it needs the same
# reconciliation — and it must not pay for it with the recorded source. A
# link-mode run that created no link leaves the project running the scripts it
# ran before, so naming the checkout it was offered would send the next plain
# `jig upgrade` to read from a checkout no link points at (adr-20260922). The
# record is kept; the source is not moved.
test_upgrade_link_mode_reconciles_a_section_without_moving_the_source() {
  skip_unless_symlinks
  fixture_repo
  jig init --from "$JIG_HOME" --link >/dev/null
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-link.XXXXXX")
  src=$(cd "$src" && pwd) # $TMPDIR can end in a slash; the manifest records a clean path
  _mk_source_v2_section "$src"
  cp .ai/manifest manifest.before.tmp

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "replace AGENTS.md (Jig section)"

  # The state an interruption leaves: section written, header not.
  cp manifest.before.tmp .ai/manifest

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "already-placed AGENTS.md (Jig section)"
  assert_contains "$OUT" "manifest updated"
  # The record was kept...
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "already-placed AGENTS.md (Jig section)"
  # ...and the source was not moved onto a checkout nothing links to.
  assert_file_contains .ai/manifest "jig.source: $JIG_HOME"

  rm -rf "$src"
}

# --- the upgrade as a unit of work (adr-20260930-an-upgrade-is-a-unit-of-work) ---

# _unit_project — an installed project with its install committed on main, the
# way a real one stands before an upgrade.
_unit_project() {
  fixture_jig_repo
  git add -A
  git commit -q -m "jig init"
}

# _unit_source — a newer source (9.9.9) in a fresh directory; prints its path.
_unit_source() {
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-unit.XXXXXX")
  src=$(cd "$src" && pwd)
  _mk_source_v2 "$src"
  printf '%s\n' "$src"
}

test_upgrade_refuses_a_dirty_tree_and_changes_nothing() {
  _unit_project
  local src head
  src=$(_unit_source)
  printf '\n# local edit\n' >> README.md
  head=$(git rev-parse HEAD)

  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "uncommitted changes"
  assert_contains "$OUT" "git stash"
  assert_contains "$OUT" "nothing was changed"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"
  assert_eq "$head" "$(git rev-parse HEAD)"
  assert_no_file .ai/skills/jig-newthing
  [ -z "$(git diff --cached --name-only)" ] || fail "the refusal staged something"
  assert_file_contains .ai/manifest "jig.source: $JIG_HOME"

  rm -rf "$src"
}

# A clean tree, and the person standing on a task's branch: the upgrade gets a
# branch of its own cut from main, and one commit on it.
test_upgrade_commits_once_on_its_own_branch_cut_from_the_base() {
  _unit_project
  jig config set --local agent.git commit >/dev/null
  local src main_head
  src=$(_unit_source)
  main_head=$(git rev-parse main)
  git checkout -q -b task/elsewhere
  printf 'task work\n' > task.txt
  git add task.txt
  git commit -q -m "task work"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "working on branch jig/upgrade-9.9.9, cut from main"
  assert_contains "$OUT" "committed "
  assert_contains "$OUT" "git checkout task/elsewhere"
  assert_eq "jig/upgrade-9.9.9" "$(git symbolic-ref --short HEAD)"
  assert_eq "$main_head" "$(git rev-parse HEAD~1)"
  assert_no_file task.txt "the upgrade branch carries the task's work"
  assert_eq "1" "$(git rev-list --count main..HEAD)"
  assert_contains "$(git log -1 --format=%s)" "Upgrade Jig "
  assert_contains "$(git log -1 --format=%s)" " -> 9.9.9"
  assert_contains "$(git log -1 --format=%B)" "Manual steps:"
  assert_contains "$(git log -1 --format=%B)" "https://jig.fapost.in/upgrading"
  assert_eq "" "$(git status --porcelain | grep -v '^??' || true)"
  assert_file_contains .ai/manifest "jig.version: 9.9.9"

  rm -rf "$src"
}

# agent.git none: the change is staged, and one command commits it. A repeat on
# the upgrade's own branch, with that change still uncommitted, is allowed:
# that is how an interrupted upgrade is finished.
test_upgrade_at_agent_git_none_stages_and_a_repeat_on_its_branch_runs() {
  _unit_project
  local src
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "git commit -F .ai/runtime/upgrade/message"
  assert_file .ai/runtime/upgrade/message
  assert_eq "jig/upgrade-9.9.9" "$(git symbolic-ref --short HEAD)"
  assert_eq "0" "$(git rev-list --count main..HEAD)"
  [ -n "$(git diff --cached --name-only)" ] || fail "nothing was staged"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "uncommitted changes"
  assert_eq "jig/upgrade-9.9.9" "$(git symbolic-ref --short HEAD)"

  rm -rf "$src"
}

test_upgrade_with_nothing_to_change_goes_back_and_drops_its_branch() {
  _unit_project
  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "nothing changed; back on main"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"
  [ -z "$(git branch --list 'jig/upgrade-*')" ] \
    || fail "the empty upgrade branch was left behind"
}

test_upgrade_without_branch_per_task_commits_on_the_current_branch() {
  _unit_project
  sed 's/^git\.branch_per_task: true/git.branch_per_task: false/' .ai/config.yaml > config.tmp
  mv config.tmp .ai/config.yaml
  git commit -q -am "one branch"
  jig config set --local agent.git pr >/dev/null
  local src
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "working on branch"
  assert_not_contains "$OUT" "pushed"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"
  assert_contains "$(git log -1 --format=%s)" " -> 9.9.9"

  rm -rf "$src"
}

# Older code hands the upgrade to the source's newer dispatcher; code as new as
# the source does the work itself.
test_upgrade_hands_itself_to_newer_code() {
  _unit_project
  local src
  src=$(_unit_source)
  printf '\nprintf "NEW-DISPATCHER\\n" >&2\n' >> "$src/scripts/lib/version.sh"
  fixture_release_source "$src"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "; handing the upgrade to 9.9.9 from $src"
  assert_contains "$OUT" "NEW-DISPATCHER"
  assert_file_contains .ai/manifest "jig.version: 9.9.9"

  rm -rf "$src"
}

test_upgrade_does_not_hand_off_to_code_no_newer_than_itself() {
  _unit_project
  local src
  src=$(_unit_source)
  _unbump_source "$src"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "handing the upgrade"

  rm -rf "$src"
}

test_upgrade_handed_off_and_still_older_says_self_update() {
  _unit_project
  local src
  src=$(_unit_source)

  JIG_UPGRADE_HANDED_OFF=0.0.1 run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "jig self-update"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"

  rm -rf "$src"
}

test_upgrade_stops_under_autocrlf_without_lf_pinned() {
  _unit_project
  git config core.autocrlf true
  git rm -q --cached .gitattributes
  rm .gitattributes
  git commit -q -m "no attributes"

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "core.autocrlf is true"
  assert_contains "$OUT" ".ai/manifest text eol=lf"
}

# A project whose .gitattributes still holds only the two lines an older
# `jig init` wrote — `.ai/scripts/**` and `.ai/profiles/**/*.sh`, never
# `.ai/manifest` — is exactly the clone the bug reached: `.ai/scripts/jig`
# reads `lf` there already, so a check that asked about it (as this one did
# before the fix) would never stop the run.
test_upgrade_stops_under_autocrlf_with_only_the_old_lines_pinned() {
  _unit_project
  git config core.autocrlf true
  printf '%s\n' "# jig: line endings of the framework's own files, whatever core.autocrlf says" \
    '.ai/scripts/** text eol=lf' '.ai/profiles/**/*.sh text eol=lf' > .gitattributes
  git add .gitattributes
  git commit -q -m "old-style attributes"

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "core.autocrlf is true"
  assert_contains "$OUT" ".ai/manifest text eol=lf"
}

test_upgrade_runs_under_autocrlf_with_lf_pinned() {
  _unit_project
  git config core.autocrlf true

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "core.autocrlf"
}

# The reproduction that opened this task: a project inits and commits here
# (LF, as every checkout on this machine is), then a second checkout is made
# the way Git for Windows makes one by default — core.autocrlf=true set
# *before* the clone, so Git itself converts every text file, `.ai/manifest`
# included. With the fix, that clone's own `jig` upgrades exactly as this
# one does: nothing looks kept-conflicting, and `jig status` reports the
# truth instead of a silent `drift: 0` that hides a manifest nobody can read.
test_upgrade_dry_run_is_clean_after_a_windows_style_clone() {
  _unit_project
  local project clone
  project="$PWD"
  clone="$JIG_TEST_TMP.win-clone"
  git -c core.autocrlf=true clone -q . "$clone"
  cd "$clone" || fail "could not enter the clone"
  git config core.autocrlf true

  run jig upgrade --from "$JIG_HOME" --dry-run
  assert_eq 0 "$RC"
  assert_contains "$OUT" "0 conflict(s)"
  assert_not_contains "$OUT" "a real upgrade would stop"

  run jig status
  assert_contains "$OUT" "drift: 0 modified"

  cd "$project" || fail "could not return from the clone"
  rm -rf "$clone"
}

# Who occupies a checkout is the one rule `task start` reads
# (jig_checkout_occupants; adr-20260930-an-upgrade-is-a-unit-of-work, amended
# 2026-10-05). The refusal that opened this task, from an installed project on
# main: a session that ran `jig status` 3h ago, and another that ran
# `jig task show` on a task whose branch was not checked out here. Neither has
# a HEAD here to lose, so neither stops the upgrade.
test_upgrade_is_not_stopped_by_a_session_that_only_ran_status() {
  _unit_project
  mkdir -p .ai/runtime/working
  printf 'command: status\n' > .ai/runtime/working/708010ad-0000-4000-8000-000000000000

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "nothing was changed"
  assert_not_contains "$OUT" "708010ad"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"
}

test_upgrade_is_not_stopped_by_a_task_whose_branch_is_not_here() {
  _unit_project
  jig task new kabanchik-k2-payments >/dev/null
  jig task start kabanchik-k2-payments >/dev/null
  git checkout -q main
  jig task show kabanchik-k2-payments >/dev/null
  assert_file .ai/runtime/working/kabanchik-k2-payments

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "nothing was changed"
  assert_not_contains "$OUT" "kabanchik-k2-payments"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"
}

# The task on HEAD is the one whose branch the upgrade takes off this checkout,
# so it is not excepted: the refusal names the task, its branch and the record,
# and the way out when that work is yours or its session is over. It quotes no
# age or command, since the record was just rewritten by this very run, and
# never advises deleting the record.
test_upgrade_stops_on_a_started_task_checked_out_here() {
  _unit_project
  jig task new T-1 >/dev/null
  jig task start T-1 >/dev/null
  local head
  head=$(git rev-parse HEAD)

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "nothing was changed"
  assert_contains "$OUT" "task T-1 is started and its branch task/T-1 is checked out here (record .ai/runtime/working/T-1)"
  assert_contains "$OUT" "\`jig task start T-1 --worktree\`"
  assert_contains "$OUT" "if another session is still working on it, run the upgrade when it has finished"
  assert_not_contains "$OUT" " ago"
  assert_not_contains "$OUT" "delete"
  assert_eq "task/T-1" "$(git symbolic-ref --short HEAD)"
  assert_eq "$head" "$(git rev-parse HEAD)"
  [ -z "$(git branch --list 'jig/upgrade-*')" ] || fail "a refused upgrade cut a branch"
}

# In the task's own worktree the main-checkout exit does not exist: the task
# already has a worktree, and `task start --worktree` cannot hand this tree the
# base branch that the main checkout holds. The refusal sends the upgrade there.
test_upgrade_in_a_tasks_own_worktree_points_to_the_main_checkout() {
  _unit_project
  jig task new T-1 >/dev/null
  local wt
  wt=$(jig task start T-1 --worktree 2>/dev/null | tail -1)
  [ -d "$wt" ] || fail "no worktree was made: $wt"
  cd "$wt" || fail "could not enter the worktree"
  jig task show T-1 >/dev/null

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "task T-1 is started and its branch task/T-1 is checked out here"
  assert_contains "$OUT" "run \`jig upgrade\` in the main checkout instead"
  assert_not_contains "$OUT" "jig task start T-1 --worktree"
  assert_eq "task/T-1" "$(git symbolic-ref --short HEAD)"

  cd - >/dev/null || fail "could not leave the worktree"
  git worktree remove --force "$wt" >/dev/null 2>&1 || true
}

# A worktree of a bare repository has no main checkout to move to: the answer to
# "is this the main checkout" is the one the rest of Jig gives (the clone root
# is the tree itself), so the refusal does not send the upgrade to a checkout
# that does not exist.
test_upgrade_in_a_bare_repositorys_worktree_does_not_name_a_main_checkout() {
  _unit_project
  local bare="$PWD/../bare.git" wt="$PWD/../bare-wt"
  git clone -q --bare "$PWD" "$bare" || fail "could not make a bare clone"
  git -C "$bare" worktree add -q "$wt" HEAD >/dev/null 2>&1 || fail "could not add a worktree"
  cd "$wt" || fail "could not enter the worktree"
  jig task new T-1 >/dev/null
  jig task start T-1 >/dev/null 2>&1
  # The bare clone has an origin; what is asked of the checkout belongs to the
  # run that works in it (upgrade.merge human, and no level that pushes).
  printf 'upgrade.merge: human\n' > .ai/config.local.yaml

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "task T-1 is started and its branch task/T-1 is checked out here"
  assert_not_contains "$OUT" "run \`jig upgrade\` in the main checkout instead"
  assert_contains "$OUT" "\`jig task start T-1 --worktree\`"
}

# With one branch for everything no HEAD moves, so, as for `task start`, the
# task on it occupies nothing the upgrade would take.
test_upgrade_without_branch_per_task_is_not_stopped_by_the_task_on_head() {
  _unit_project
  sed 's/^git\.branch_per_task: true/git.branch_per_task: false/' .ai/config.yaml > config.tmp
  mv config.tmp .ai/config.yaml
  git commit -q -am "one branch"
  jig task new T-1 >/dev/null
  jig task start T-1 >/dev/null

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "is started and its branch"
}

test_upgrade_stops_while_verify_runs_in_this_checkout() {
  _unit_project
  mkdir -p .ai/runtime/verify/busy
  printf 'checkout: %s\npid: %s\n' "$PWD" "$$" > .ai/runtime/verify/busy/run

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "\`jig verify\` is running in this checkout"

  rm -rf .ai/runtime/verify/busy
  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
}

# A dry run is read-only and is what status, verify and doctor run: it never
# refuses, it only says what a real run would do.
test_upgrade_dry_run_on_a_dirty_tree_only_notes_it() {
  _unit_project
  printf '\n# local edit\n' >> README.md

  run jig upgrade --dry-run --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "note: a real upgrade would stop: the working tree has uncommitted changes"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"

  run jig status
  assert_not_contains "$OUT" "note: a real upgrade"
}

# At upgrade.merge human and agent.git pr the branch is pushed by the steps `task
# ship` takes, from Jig's own tree; with no forge CLI usable here, the pull
# request is left to the person, and said so. The checkout is never moved.
test_upgrade_at_agent_git_pr_pushes_its_branch() {
  _unit_project
  local src remote
  remote=$(mktemp -d "${TMPDIR:-/tmp}/jig-remote.XXXXXX")
  git init -q --bare "$remote"
  git remote add origin "$remote"
  git push -q origin main
  jig config set --local agent.git pr upgrade.merge human >/dev/null
  src=$(_unit_source)
  local before
  before=$(git rev-parse HEAD)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "pushed jig/upgrade-9.9.9"
  git -C "$remote" show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 \
    || fail "the upgrade branch did not reach origin"
  # The upgrade waits on its branch, which is checked out nowhere, so
  # housekeeping can delete it once it is merged.
  assert_contains "$OUT" "next: this upgrade is on branch jig/upgrade-9.9.9"
  assert_not_contains "$OUT" "back on"
  assert_eq main "$(git symbolic-ref --short HEAD)"
  assert_eq "$before" "$(git rev-parse HEAD)"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the local upgrade branch was deleted"

  rm -rf "$src" "$remote"
}

# The merge request an upgrade opens on GitLab is in the forge cache at once,
# so `jig status` says the upgrade waits for it without a housekeeping run in
# between — in a project nobody starts a session in, that run may be weeks
# away (task gitlab-upgrade-mr-in-status). The line replaces the cache's older
# line for the same branch and base and keeps every other one.
test_upgrade_records_the_merge_request_it_opened_for_status() {
  _unit_project
  local src remote t dir
  t=$(printf '\t')
  sed 's|^forge:.*|forge: gitlab|' .ai/config.yaml > .ai/config.yaml.tmp
  mv .ai/config.yaml.tmp .ai/config.yaml
  git commit -q -am "fixture: gitlab is the forge"
  remote=$(mktemp -d "${TMPDIR:-/tmp}/jig-remote.XXXXXX")
  git init -q --bare "$remote"
  git remote add origin "$remote"
  git push -q origin main
  jig config set --local agent.git pr upgrade.merge human >/dev/null
  dir="$PWD"
  mkdir -p stub-bin .ai/runtime
  cat > stub-bin/glab <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "mr list") printf '[]\n' ;;
  "mr create") printf 'Creating merge request\nhttps://gitlab.com/example/example/-/merge_requests/157\n' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x stub-bin/glab
  printf 'stub-bin/\n' >> .git/info/exclude
  printf '%s\n' "jig/upgrade-9.9.9${t}main${t}closed${t}-${t}2026-10-01T00:00:00Z${t}-${t}-${t}-" \
    "task/other${t}main${t}open${t}green${t}2026-10-01T00:00:00Z${t}def456${t}https://gitlab.com/example/example/-/merge_requests/11${t}-" \
    > .ai/runtime/forge-cache
  src=$(_unit_source)

  PATH="$dir/stub-bin:$PATH"
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "https://gitlab.com/example/example/-/merge_requests/157"
  assert_eq main "$(git symbolic-ref --short HEAD)"

  local rows
  rows=$(sed '/^#/d' .ai/runtime/forge-cache)
  assert_eq 2 "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
  assert_contains "$(printf '%s\n' "$rows" | head -n 1)" \
    "jig/upgrade-9.9.9${t}main${t}open${t}-${t}"
  assert_contains "$(printf '%s\n' "$rows" | head -n 1)" \
    "${t}$(git rev-parse jig/upgrade-9.9.9)${t}https://gitlab.com/example/example/-/merge_requests/157${t}-"
  assert_contains "$rows" "task/other${t}main${t}open${t}green${t}2026-10-01T00:00:00Z"

  run jig status
  assert_contains "$OUT" "upgrade pull request: jig/upgrade-9.9.9 into main open as of"
  assert_contains "$OUT" "(https://gitlab.com/example/example/-/merge_requests/157)"

  rm -rf "$src" "$remote"
}

# Started on another branch, pushed at agent.git push: the checkout was never
# moved, so there is nothing to go back to.
test_upgrade_pushed_leaves_the_branch_it_started_on_alone() {
  _unit_project
  local src remote
  remote=$(mktemp -d "${TMPDIR:-/tmp}/jig-remote.XXXXXX")
  git init -q --bare "$remote"
  git remote add origin "$remote"
  git push -q origin main
  jig config set --local agent.git push upgrade.merge human >/dev/null
  src=$(_unit_source)
  git checkout -q -b task/elsewhere

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "pushed jig/upgrade-9.9.9"
  assert_not_contains "$OUT" "back on"
  assert_eq task/elsewhere "$(git symbolic-ref --short HEAD)"

  rm -rf "$src" "$remote"
}

# Committed only, nothing pushed: the run stays on its branch, which holds the
# one copy of the upgrade.
test_upgrade_committed_only_stays_on_its_branch() {
  _unit_project
  jig config set --local agent.git commit >/dev/null
  local src
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "back on"
  assert_eq jig/upgrade-9.9.9 "$(git symbolic-ref --short HEAD)"

  rm -rf "$src"
}

# _upgrade_merge_project [<level>] — _unit_project with an origin, GitHub as
# the forge (committed, as a project setting is) and agent.git <level> (default
# merge), with a fake `gh` in stub-bin/ that opens, checks and merges whatever is
# shipped: its `pr view` answers with the newest upgrade branch's head (the
# upgrade is built in Jig's own tree, so the checkout's HEAD is not the shipped
# commit), its checks with what stub-bin/checks holds (green by default), and
# its merge moves the bare remote's main to the commit it was asked to merge.
# Prints the bare remote's path; the caller removes it, and puts stub-bin/ on
# PATH itself, since a `$(...)` would lose the change.
_upgrade_merge_project() {
  local remote dir level="${1:-merge}"
  _unit_project
  sed 's|^forge:.*|forge: github|' .ai/config.yaml > .ai/config.yaml.tmp
  mv .ai/config.yaml.tmp .ai/config.yaml
  git commit -q -am "fixture: github is the forge"
  remote=$(mktemp -d "${TMPDIR:-/tmp}/jig-remote.XXXXXX")
  git init -q --bare "$remote"
  git remote add origin "$remote"
  git push -q origin main
  git fetch -q origin
  jig config set --local agent.git "$level" agent.ci_timeout 0 >/dev/null
  dir="$PWD"
  mkdir -p stub-bin
  printf 'pass\n' > stub-bin/checks
  cat > stub-bin/gh <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr list") printf 'null\n' ;;
  "pr create") printf 'https://github.com/example/example/pull/7\n' ;;
  "pr view") printf 'false %s\n' "\$(git -C "$dir" for-each-ref --sort=-committerdate --count=1 --format='%(objectname)' 'refs/heads/jig/upgrade-*')" ;;
  "repo view") printf 'true true true\n' ;;
  "pr checks") cat "$dir/stub-bin/checks" ;;
  "pr merge") printf '%s\n' "\$*" > "$dir/stub-bin/merged"; git -C "$remote" update-ref refs/heads/main "\$5" ;;
esac
STUB
  chmod +x stub-bin/gh
  printf 'stub-bin/\n' >> .git/info/exclude
  printf '%s\n' "$remote"
}

# Merged by the upgrade itself: no branch is left behind, here or on origin, and
# the checkout, standing on main, takes the new Jig by the base's fast-forward
# (adr-20261007-a-merged-branch-leaves-with-its-work).
test_upgrade_merged_leaves_no_branch_and_moves_the_base_under_the_checkout() {
  local src remote
  remote=$(_upgrade_merge_project)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "merged https://github.com/example/example/pull/7"
  assert_contains "$OUT" "upgrade: main here moved to"
  assert_contains "$OUT" "upgrade: deleted branch jig/upgrade-9.9.9"
  assert_contains "$OUT" "upgrade: deleted branch jig/upgrade-9.9.9 on origin"
  assert_not_contains "$OUT" "once it is merged"
  assert_eq main "$(git symbolic-ref --short HEAD)"
  assert_file .claude/skills/jig-newthing/SKILL.md
  assert_file_contains .ai/manifest "jig.version: 9.9.9"
  if git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9; then fail "the local branch is still here"; fi
  if git -C "$remote" show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9; then fail "the branch is still on origin"; fi

  rm -rf "$src" "$remote"
}

# Started on another branch: the checkout stays there, and the run names what that
# branch does to take the upgrade.
test_upgrade_merged_from_another_branch_names_the_way_forward() {
  local src remote
  remote=$(_upgrade_merge_project)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  git checkout -q -b task/elsewhere

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "back on"
  assert_contains "$OUT" "next: task/elsewhere is still on Jig"
  assert_contains "$OUT" "\`git merge main\`"
  assert_eq task/elsewhere "$(git symbolic-ref --short HEAD)"
  git show-ref --verify --quiet refs/heads/task/elsewhere || fail "a branch that is not Jig's was deleted"

  rm -rf "$src" "$remote"
}

test_upgrade_merged_keeps_its_branch_when_the_key_is_off() {
  local src remote
  remote=$(_upgrade_merge_project)
  PATH="$PWD/stub-bin:$PATH"
  jig config set --local git.delete_merged_branches false >/dev/null
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "merged https://github.com/example/example/pull/7"
  assert_not_contains "$OUT" "deleted branch"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the local branch was deleted"
  git -C "$remote" show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "origin's branch was deleted"

  rm -rf "$src" "$remote"
}

# An upgrade to this version already waiting on its own branch is not started
# a second time on another one: that could only become a second pull request.
test_upgrade_refuses_a_second_branch_for_an_unmerged_upgrade() {
  _unit_project
  local src
  src=$(_unit_source)
  git checkout -q -b jig/upgrade-9.9.9
  git commit -q --allow-empty -m "earlier upgrade, not merged"
  git checkout -q main

  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "already on branch jig/upgrade-9.9.9, which has not been merged into main"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"
  [ -z "$(git branch --list 'jig/upgrade-9.9.9-*')" ] || fail "a second upgrade branch was cut"

  # No forge to ask: the refusal names no pull request and reads `failed`.
  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"error":{"code":"failed","message":"upgrade: the upgrade to 9.9.9 is already on branch jig/upgrade-9.9.9, which has not been merged into main yet. Merge it, or'

  rm -rf "$src"
}

# The base already current and the person on a task branch that is not: the
# way forward is the base, and the run says so instead of leaving them to loop.
test_upgrade_with_nothing_to_change_names_the_base_to_merge() {
  _unit_project
  git checkout -q -b task/behind

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "nothing changed; back on task/behind"
  assert_contains "$OUT" "git merge main"
}

test_upgrade_refuses_when_the_base_branch_exists_nowhere() {
  _unit_project
  sed 's/^git\.base_branch: main/git.base_branch: trunk/' .ai/config.yaml > config.tmp
  mv config.tmp .ai/config.yaml
  git commit -q -am "trunk"

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "no branch trunk here or on origin"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"
}

test_upgrade_refuses_an_invalid_agent_git_before_touching_anything() {
  _unit_project
  printf 'agent.git: sometimes\n' > .ai/config.local.yaml

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "invalid agent.git: sometimes"
  assert_contains "$OUT" "nothing was changed"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"
}

# A pull request squashed by the forge leaves the local upgrade branch behind as
# no ancestor of the base; the base's manifest says the upgrade landed anyway.
test_upgrade_reads_a_squashed_upgrade_branch_as_landed() {
  _unit_project
  git checkout -q -b jig/upgrade-7.7.7
  git commit -q --allow-empty -m "the upgrade, as its branch had it"
  git checkout -q main
  sed 's/^jig\.version: .*/jig.version: 7.7.7/' .ai/manifest > manifest.tmp
  mv manifest.tmp .ai/manifest
  git commit -q -am "the upgrade, squashed"
  local src
  src=$(_unit_source)
  sed 's/^JIG_VERSION=.*/JIG_VERSION="7.7.7"/' "$src/scripts/lib/version.sh" > "$src/v.tmp"
  mv "$src/v.tmp" "$src/scripts/lib/version.sh"
  fixture_release_source "$src"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "has not been merged"
  assert_contains "$OUT" "working on branch jig/upgrade-7.7.7-2"

  rm -rf "$src"
}

test_upgrade_says_nothing_changed_when_its_branch_cannot_be_made() {
  _unit_project
  git branch jig/upgrade-"$(sed -n 's/^JIG_VERSION="\(.*\)"/\1/p' "$JIG_HOME/scripts/lib/version.sh")"/blocker

  run jig upgrade --from "$JIG_HOME"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "could not create branch"
  assert_contains "$OUT" "nothing was changed"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"
}

# --- the manual checklist (_upgrade_manual_steps, upgrade-carries-its-own-checklist) ---

# _unit_project_from <version> — _unit_project with the manifest's recorded
# jig.version rewritten, so the upgrade that follows sees it as coming from
# <version> rather than from the running JIG_VERSION.
_unit_project_from() {
  _unit_project
  sed "s/^jig\\.version: .*/jig.version: $1/" .ai/manifest > manifest.tmp
  mv manifest.tmp .ai/manifest
  git commit -q -am "back-date to $1"
}

test_upgrade_manual_steps_name_the_outstanding_ones() {
  _unit_project_from 0.15.1
  jig config set --local agent.git commit >/dev/null
  grep -v 'jig:begin\|jig:end' AGENTS.md > AGENTS.md.new
  mv AGENTS.md.new AGENTS.md
  git commit -q -am "unmark AGENTS.md"
  local src
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$(git log -1 --format=%B)" "Run the jig-init skill"
  assert_contains "$(git log -1 --format=%B)" "Install the tools your project's checks need"
  assert_contains "$(git log -1 --format=%B)" "jig verify"

  rm -rf "$src"
}

test_upgrade_manual_steps_skip_the_marker_one_once_current() {
  _unit_project_from 0.15.1
  jig config set --local agent.git commit >/dev/null
  local src
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$(git log -1 --format=%B)" "Run the jig-init skill"
  assert_contains "$(git log -1 --format=%B)" "Install the tools your project's checks need"

  rm -rf "$src"
}

test_upgrade_manual_steps_name_a_custom_profile() {
  _unit_project_from 0.15.1
  jig config set --local agent.git commit >/dev/null
  mkdir -p .ai/profiles/homegrown
  printf 'name: homegrown\ndetect: always\n' > .ai/profiles/homegrown/profile.yaml
  sed 's/^profiles:.*/profiles: [generic, homegrown]/' .ai/config.yaml > config.tmp
  mv config.tmp .ai/config.yaml
  git add .ai/profiles/homegrown/profile.yaml
  git commit -q -am "a profile of our own"
  local src
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  # shellcheck disable=SC2016
  assert_contains "$(git log -1 --format=%B)" 'If homegrown checks nothing by design, add `verifies: nothing`'

  rm -rf "$src"
}

test_upgrade_manual_steps_silent_when_project_is_no_older_than_0_16_0() {
  _unit_project
  jig config set --local agent.git commit >/dev/null
  grep -v 'jig:begin\|jig:end' AGENTS.md > AGENTS.md.new
  mv AGENTS.md.new AGENTS.md
  git commit -q -am "unmark AGENTS.md"
  local src
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$(git log -1 --format=%B)" "Run the jig-init skill"
  assert_not_contains "$(git log -1 --format=%B)" "Install the tools your project's checks need"

  rm -rf "$src"
}

# --- the report's two forms (adr-20261005-output-is-decorated-only-on-a-terminal)

# _report_scenario — a committed project and a source (printed) that make one
# run produce every kind of line a person may have to act on: replacements in
# three places, installs, a deletion, a file kept because it was edited, one
# kept because it is in the way, and an AGENTS.md whose end marker is gone,
# which is reported with an explanation under it. The source keeps
# the running version, so this code writes the report.
_report_scenario() {
  _unit_project
  local src
  src=$(_unit_source)
  _unbump_source "$src"
  printf '\n<!-- v2 -->\n' >> "$src/skills/jig-review/SKILL.md"
  printf '\n<!-- v2 -->\n' >> "$src/skills/jig-verify/SKILL.md"
  rm -f "$src/profiles/generic/profile.yaml"
  fixture_release_source "$src"
  printf '\n# local edit\n' >> .ai/scripts/lib/config.sh
  mkdir -p .claude/skills/jig-newthing
  echo "pre-existing, not from jig" > .claude/skills/jig-newthing/SKILL.md
  grep -v 'jig:end' AGENTS.md > AGENTS.md.new
  mv AGENTS.md.new AGENTS.md
  git add -A
  git commit -q -m "local changes"
  printf '%s\n' "$src"
}

_report_branch() {
  printf 'jig/upgrade-%s' "$(sed -n 's/^JIG_VERSION="\(.*\)"$/\1/p' "$JIG_HOME/scripts/lib/version.sh")"
}

# The byte-for-byte proof: the expected text is the report in the format
# upgrade printed before the output layer, and the same test passes on the
# commit before it (upgrade-says-what-changed, verification.md).
test_upgrade_a_pipe_gets_the_report_byte_for_byte_as_before() {
  local src branch
  src=$(_report_scenario)
  branch=$(_report_branch)
  {
    printf 'upgrade: working on branch %s, cut from main\n' "$branch"
    printf 'delete .ai/profiles/generic/profile.yaml\n'
    printf 'replace .ai/profiles/generic/verify.sh\n'
    printf 'keep-modified .ai/scripts/lib/config.sh\n'
    printf 'keep-conflict .claude/skills/jig-newthing/SKILL.md\n'
    printf 'replace .claude/skills/jig-review/SKILL.md\n'
    printf 'replace .claude/skills/jig-verify/SKILL.md\n'
    printf 'install .codex/skills/jig-newthing/SKILL.md\n'
    printf 'replace .codex/skills/jig-review/SKILL.md\n'
    printf 'replace .codex/skills/jig-verify/SKILL.md\n'
    printf 'keep-malformed AGENTS.md (Jig section)\n'
    printf '  expected one <!-- jig:begin --> and one <!-- jig:end -->, in that order\n'
    printf 'jig upgrade: 6 placed, N kept, 1 removed, 1 conflict(s); manifest updated\n'
    # shellcheck disable=SC2016
    printf 'upgrade: the change is staged; commit it with `git commit -F .ai/runtime/upgrade/message`\n'
    printf 'next: this upgrade is on branch %s; once it is merged into main, merge that into the branches still in progress\n' "$branch"
    # shellcheck disable=SC2016
    printf 'next: to go back to what you were doing: `git checkout main`\n'
  } > "$TMPDIR/expected.txt"
  # The kept count moves with the number of files Jig ships, so it is the one
  # thing not pinned.
  jig upgrade --from "$src" 2>&1 \
    | sed -E 's/^(jig upgrade: 6 placed, )[0-9]+( kept)/\1N\2/' > "$TMPDIR/actual.txt"
  assert_eq 0 "${PIPESTATUS[0]}"
  cmp "$TMPDIR/expected.txt" "$TMPDIR/actual.txt" || fail "piped report changed: $(diff "$TMPDIR/expected.txt" "$TMPDIR/actual.txt")"
  rm -rf "$src"
}

test_upgrade_a_terminal_groups_the_replacements_and_keeps_the_rest() {
  local src branch
  src=$(_report_scenario)
  branch=$(_report_branch)
  run env JIG_TERMINAL=1 NO_COLOR=1 "$JIG_BIN" upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "ok    replace 5 file(s): .ai/profiles, .claude/skills (2), .codex/skills (2)"
  assert_not_contains "$OUT" "replace .ai/profiles/generic/verify.sh"
  assert_contains "$OUT" "ok    install .codex/skills/jig-newthing/SKILL.md"
  assert_contains "$OUT" "ok    delete .ai/profiles/generic/profile.yaml"
  assert_contains "$OUT" "warn  keep-modified .ai/scripts/lib/config.sh"
  assert_contains "$OUT" "warn  keep-conflict .claude/skills/jig-newthing/SKILL.md"
  assert_contains "$OUT" "warn  keep-malformed AGENTS.md (Jig section)"
  assert_contains "$OUT" "      note: expected one <!-- jig:begin --> and one <!-- jig:end -->, in that order"
  assert_contains "$OUT" "upgrade: working on branch $branch, cut from main"
  # The grouped line comes right before the summary, after every expanded one.
  local before
  before=$(printf '%s\n' "$OUT" | grep -B1 '^jig upgrade: 6 placed, ' | sed -n 1p)
  assert_contains "$before" "ok    replace 5 file(s): "
  # The commit message carries the summary in plain words.
  assert_contains "$(cat .ai/runtime/upgrade/message)" "jig upgrade: 6 placed, "
  rm -rf "$src"
}

test_upgrade_a_terminal_colours_the_level_words() {
  local src esc
  src=$(_report_scenario)
  esc=$(printf '\033')
  run env -u NO_COLOR TERM=xterm JIG_TERMINAL=1 "$JIG_BIN" upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "${esc}[32mok${esc}[0m    replace 5 file(s): "
  assert_contains "$OUT" "${esc}[33mwarn${esc}[0m  keep-modified .ai/scripts/lib/config.sh"
  assert_not_contains "$(cat .ai/runtime/upgrade/message)" "$esc"
  rm -rf "$src"
}

# The two readers inside jig — upgrade_pending and the self-check — filter the
# plain lines, so a reader who asked for the terminal form must not blind them.
test_upgrade_a_terminal_reader_does_not_blind_the_pending_check() {
  fixture_jig_repo
  rm -f .ai/scripts/lib/spec.sh
  run env JIG_TERMINAL=1 NO_COLOR=1 "$JIG_BIN" status
  assert_eq 0 "$RC"
  assert_contains "$OUT" "1 pending"
}

test_upgrade_a_terminal_reader_still_hears_what_is_not_installed() {
  fixture_jig_repo
  local src anchor
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-next.XXXXXX")
  _mk_source_v2 "$src"
  _unbump_source "$src"
  # shellcheck disable=SC2016
  anchor='cp -p "$source/templates/AGENTS.md" "$stage/.ai/templates/AGENTS.md"'
  grep -qF "$anchor" "$src/scripts/lib/upgrade.sh" \
    || fail "the staging line this test patches is gone; rewrite the test"
  awk -v anchor="$anchor" '
    { print }
    index($0, anchor) { print "  cp -p \"$source/templates/AGENTS.md\" \"$stage/.ai/templates/NEWTHING.md\"" }
  ' "$src/scripts/lib/upgrade.sh" > "$src/scripts/lib/upgrade.sh.tmp"
  mv "$src/scripts/lib/upgrade.sh.tmp" "$src/scripts/lib/upgrade.sh"
  fixture_release_source "$src"

  run env JIG_TERMINAL=1 NO_COLOR=1 "$JIG_BIN" upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "fail  1 item(s) still not installed"
  assert_contains "$OUT" "      install .ai/templates/NEWTHING.md"
  rm -rf "$src"
}

# --- jig upgrade --json (task upgrade-json) ----------------------------------

# _up_json <args> — run jig with stdout in OUT and stderr in ERR, apart.
_up_json() {
  local o e
  o=$(mktemp "${TMPDIR:-/tmp}/jig-up-out.XXXXXX")
  e=$(mktemp "${TMPDIR:-/tmp}/jig-up-err.XXXXXX")
  set +e
  jig "$@" >"$o" 2>"$e"
  RC=$?
  set -e
  OUT=$(cat "$o")
  ERR=$(cat "$e")
  rm -f "$o" "$e"
}

# One envelope on stdout, the text form on stderr, and the data a program acts
# on: what changed and how far git went, at agent.git commit. The source is
# newer than this jig, so the run is handed off and the newer one's data lands
# in this envelope.
test_upgrade_json_reports_a_committed_upgrade() {
  _unit_project
  jig config set --local agent.git commit >/dev/null
  local src from sha
  src=$(_unit_source)
  from=$(sed -n 's/^jig.version: //p' .ai/manifest)

  _up_json upgrade --from "$src" --json
  assert_eq 0 "$RC" "$ERR"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c .)" "stdout held more than one line: $OUT"
  sha=$(git rev-parse HEAD)
  assert_contains "$OUT" '"data":{"mode":"copy","dry_run":false,"from":"'"$from"'","to":"9.9.9","outcome":"upgraded","files":{"placed":'
  assert_contains "$OUT" '"git":{"level":"commit","branch":"jig/upgrade-9.9.9","commit":"'"$sha"'","pushed":false,"pull_request":null,"merged":false,"level_key":"agent.git","path":"checkout","ignored":[],"fell_back":null,"merge_by":"agent","not_merged":null,"base":null,"superseded":[]}'
  assert_contains "$OUT" '"would_stop":[]}'
  assert_contains "$ERR" "committed "
  assert_contains "$ERR" "handing the upgrade to 9.9.9"

  rm -rf "$src"
}

test_upgrade_json_reports_a_staged_upgrade_and_a_dry_run() {
  _unit_project
  local src
  src=$(_unit_source)

  _up_json upgrade --from "$src" --dry-run --json
  assert_eq 0 "$RC" "$ERR"
  assert_contains "$OUT" '"dry_run":true'
  assert_contains "$OUT" '"outcome":"planned"'
  assert_contains "$OUT" '"git":null'

  _up_json upgrade --from "$src" --json
  assert_eq 0 "$RC" "$ERR"
  assert_contains "$OUT" '"outcome":"staged"'
  assert_contains "$OUT" '"git":{"level":"none","branch":"jig/upgrade-9.9.9","commit":null,"pushed":false'

  rm -rf "$src"
}

# A refusal before anything is touched is an envelope a program can act on.
test_upgrade_json_refuses_a_blocked_run_with_its_code() {
  _unit_project
  local src head
  src=$(_unit_source)
  head=$(git rev-parse HEAD)
  printf 'work\n' >> README.md 2>/dev/null || printf 'work\n' > README.md
  git add README.md

  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"error":{"code":"upgrade-blocked","message":"upgrade: nothing was changed:\n  - the working tree has uncommitted changes'
  assert_eq "$head" "$(git rev-parse HEAD)"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"

  rm -rf "$src"
}

test_upgrade_json_reports_nothing_to_do_and_refuses_an_argument_as_usage() {
  _unit_project
  _up_json upgrade --json
  assert_eq 0 "$RC" "$ERR"
  assert_contains "$OUT" '"outcome":"nothing-to-do"'
  assert_contains "$OUT" '"git":null'

  _up_json upgrade --bogus --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"error":{"code":"usage","message":"upgrade: unknown argument: --bogus"}'
  _up_json upgrade --json --from
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"error":{"code":"usage","message":"upgrade: --from requires a value"}'
}


# --- jig upgrade --land (task upgrade-land) ------------------------------------

# _land_project <state> [squash] [gitlab] — an installed project on main with
# an origin, GitHub (or GitLab) as the forge and agent.git pr, whose upgrade to 9.9.9 went out as a
# pull request: branch jig/upgrade-9.9.9 pushed with its upstream, this
# checkout back on main at the old Jig. With <state> merged, origin's main
# has the upgrade — by fast-forward, or as a commit of its own with `squash`,
# as a forge's squash merge leaves it. A fake `gh` answers `pr list` with the
# pull request in <state>, a fake `glab` `mr list` with it as GitLab's JSON
# (its author's web_url first), and both record their calls in stub-bin/calls. Sets
# LAND_REMOTE (the bare remote; the caller removes it) and LAND_SHA (the
# branch's head); puts stub-bin/ on PATH for the caller through LAND_PATH.
_land_project() {
  local state="$1" squash="${2:-}" forge="${3:-github}" dir work glab_state
  _unit_project
  sed "s|^forge:.*|forge: $forge|" .ai/config.yaml > .ai/config.yaml.tmp
  mv .ai/config.yaml.tmp .ai/config.yaml
  git commit -q -am "fixture: github is the forge"
  LAND_REMOTE=$(mktemp -d "${TMPDIR:-/tmp}/jig-remote.XXXXXX")
  git init -q --bare "$LAND_REMOTE"
  git remote add origin "$LAND_REMOTE"
  git push -q origin main
  git fetch -q origin
  git branch -q --set-upstream-to=origin/main main
  jig config set --local agent.git pr >/dev/null
  git checkout -q -b jig/upgrade-9.9.9
  sed 's/^jig\.version: .*/jig.version: 9.9.9/' .ai/manifest > manifest.tmp
  mv manifest.tmp .ai/manifest
  git commit -q -am "Upgrade Jig to 9.9.9"
  git push -q -u origin jig/upgrade-9.9.9
  LAND_SHA=$(git rev-parse HEAD)
  git checkout -q main
  if [ "$state" = merged ]; then
    if [ -n "$squash" ]; then
      work=$(mktemp -d "${TMPDIR:-/tmp}/jig-land-work.XXXXXX")
      git clone -q "$LAND_REMOTE" "$work"
      ( cd "$work" && git checkout -q main \
        && sed 's/^jig\.version: .*/jig.version: 9.9.9/' .ai/manifest > manifest.tmp \
        && mv manifest.tmp .ai/manifest && git commit -q -am "Upgrade Jig to 9.9.9 (#12)" \
        && git push -q origin main )
      rm -rf "$work"
    else
      git push -q origin "$LAND_SHA:refs/heads/main"
    fi
  fi
  dir="$PWD"
  mkdir -p stub-bin
  printf 'jig/upgrade-9.9.9\t%s\t%s\thttps://github.com/example/example/pull/12\n' \
    "$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')" "$LAND_SHA" > stub-bin/prs
  cat > stub-bin/gh <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/stub-bin/calls"
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "pr list") cat "$dir/stub-bin/prs" ;;
  *) exit 1 ;;
esac
STUB
  glab_state=$state
  [ "$state" != open ] || glab_state=opened
  printf '[{"iid":12,"source_branch":"jig/upgrade-9.9.9","target_branch":"main","state":"%s","author":{"web_url":"https://gitlab.com/someone"},"sha":"%s","web_url":"https://gitlab.com/example/example/-/merge_requests/12"}]\n' \
    "$glab_state" "$LAND_SHA" > stub-bin/mrs
  cat > stub-bin/glab <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/stub-bin/calls"
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "mr list") cat "$dir/stub-bin/mrs" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x stub-bin/gh stub-bin/glab
  printf 'stub-bin/\nmanifest.tmp\n' >> .git/info/exclude
  LAND_PATH="$PWD/stub-bin:$PATH"
}

# The merged upgrade is brought here from main: fast-forwarded to origin's,
# the branch let go here and on origin, at the head the forge merged.
test_upgrade_land_brings_a_merged_upgrade_here() {
  _land_project merged
  PATH=$LAND_PATH

  run jig upgrade --land
  assert_eq 0 "$RC"
  assert_contains "$OUT" "upgrade: landed jig/upgrade-9.9.9 (https://github.com/example/example/pull/12); on main at"
  assert_contains "$OUT" "upgrade: deleted branch jig/upgrade-9.9.9"
  assert_contains "$OUT" "upgrade: deleted branch jig/upgrade-9.9.9 on origin"
  assert_eq main "$(git symbolic-ref --short HEAD)"
  assert_eq "$(git rev-parse origin/main)" "$(git rev-parse HEAD)"
  assert_file_contains .ai/manifest "jig.version: 9.9.9"
  if git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9; then fail "the local branch is still here"; fi
  if git -C "$LAND_REMOTE" show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9; then fail "the branch is still on origin"; fi
  assert_contains "$(cat stub-bin/calls)" "pr list --state all --base main"

  # Landed once, there is nothing left to land.
  run jig upgrade --land
  assert_eq 0 "$RC"
  assert_contains "$OUT" "upgrade: no merged upgrade waits to be brought here"

  rm -rf "$LAND_REMOTE"
}

# A squash merge leaves the branch out of main's history; standing on the
# upgrade branch itself, --land still goes back to main and lets it go.
test_upgrade_land_from_the_upgrade_branch_after_a_squash_merge() {
  _land_project merged squash
  PATH=$LAND_PATH
  git checkout -q jig/upgrade-9.9.9

  run jig upgrade --land
  assert_eq 0 "$RC"
  assert_eq main "$(git symbolic-ref --short HEAD)"
  assert_eq "$(git rev-parse origin/main)" "$(git rev-parse HEAD)"
  assert_contains "$(git log -1 --format=%s)" "(#12)"
  assert_contains "$OUT" "upgrade: deleted branch jig/upgrade-9.9.9"
  if git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9; then fail "the local branch is still here"; fi

  rm -rf "$LAND_REMOTE"
}

# An open pull request is not landed: nothing moves, and the refusal names it.
test_upgrade_land_refuses_an_upgrade_not_merged_yet() {
  _land_project open
  PATH=$LAND_PATH
  local head
  head=$(git rev-parse HEAD)

  run jig upgrade --land
  assert_eq 1 "$RC"
  assert_contains "$OUT" "the pull request of jig/upgrade-9.9.9 is not merged yet (https://github.com/example/example/pull/12)"
  assert_contains "$OUT" "Nothing was changed"
  assert_eq "$head" "$(git rev-parse HEAD)"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the branch was deleted"

  _up_json upgrade --land --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"error":{"code":"not-merged","message":"upgrade --land: the pull request of jig/upgrade-9.9.9 is not merged yet'

  rm -rf "$LAND_REMOTE"
}

# The upgrade already waiting in an open pull request is not started again,
# and the refusal names that pull request, as `not-merged`: done, waiting for
# a merge, not failed. The forge is asked once.
test_upgrade_refusal_names_the_open_pull_request() {
  _land_project open
  PATH=$LAND_PATH
  jig config set --local upgrade.merge human >/dev/null
  local src
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "already on branch jig/upgrade-9.9.9, which has not been merged into main yet; its pull request is open and waits for a merge: https://github.com/example/example/pull/12"
  assert_contains "$OUT" "jig upgrade --land"
  assert_eq 1 "$(grep -c '^pr list' stub-bin/calls)"
  assert_contains "$(cat stub-bin/calls)" "--head jig/upgrade-9.9.9"
  assert_eq main "$(git symbolic-ref --short HEAD)"
  [ -z "$(git branch --list 'jig/upgrade-9.9.9-*')" ] || fail "a second upgrade branch was cut"

  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"error":{"code":"not-merged","message":"upgrade: the upgrade to 9.9.9 is already on branch jig/upgrade-9.9.9'

  rm -rf "$src" "$LAND_REMOTE"
}

test_upgrade_refusal_names_the_open_merge_request_on_gitlab() {
  _land_project open "" gitlab
  PATH=$LAND_PATH
  jig config set --local upgrade.merge human >/dev/null
  local src
  src=$(_unit_source)

  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"code":"not-merged"'
  assert_contains "$OUT" "its pull request is open and waits for a merge: https://gitlab.com/example/example/-/merge_requests/12"
  assert_eq 1 "$(grep -c '^mr list' stub-bin/calls)"
  assert_contains "$(cat stub-bin/calls)" "--source-branch jig/upgrade-9.9.9"

  rm -rf "$src" "$LAND_REMOTE"
}

# A pull request closed without a merge is named with its state; the upgrade
# is not waiting for anything, so the refusal stays `failed`.
test_upgrade_refusal_names_a_closed_pull_request() {
  _land_project closed
  PATH=$LAND_PATH
  jig config set --local upgrade.merge human >/dev/null
  local src
  src=$(_unit_source)

  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"code":"failed"'
  assert_contains "$OUT" "its pull request was closed without a merge: https://github.com/example/example/pull/12"

  rm -rf "$src" "$LAND_REMOTE"
}

# A forge that does not answer leaves the refusal as it always was: no other
# error, and still `failed`.
test_upgrade_refusal_stays_when_the_forge_does_not_answer() {
  _land_project open
  PATH=$LAND_PATH
  jig config set --local upgrade.merge human >/dev/null
  rm -f stub-bin/prs
  local src
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "already on branch jig/upgrade-9.9.9, which has not been merged into main yet. Merge it, or"
  assert_not_contains "$OUT" "pull request"

  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"error":{"code":"failed","message":"upgrade: the upgrade to 9.9.9 is already on branch jig/upgrade-9.9.9'

  rm -rf "$src" "$LAND_REMOTE"
}

# On somebody else's branch, with uncommitted work in the tree, the checkout
# is never switched (task upgrade-land-without-checkout): main's ref is
# fast-forwarded to origin's, the upgrade's branch let go, and the tree, its
# changes and HEAD stay as they were. Nothing is stashed.
test_upgrade_land_from_another_branch_leaves_the_checkout_alone() {
  _land_project merged
  PATH=$LAND_PATH
  local head
  git checkout -q -b task/elsewhere
  printf 'work\n' >> README.md
  head=$(git rev-parse HEAD)

  run jig upgrade --land
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "upgrade: landed jig/upgrade-9.9.9 (https://github.com/example/example/pull/12); main at"
  assert_contains "$OUT" "this checkout stays on task/elsewhere"
  assert_contains "$OUT" "next: task/elsewhere is still at Jig $(sed -n 's/^jig.version: //p' .ai/manifest); merge main into it to take the upgrade"
  assert_contains "$OUT" "upgrade: deleted branch jig/upgrade-9.9.9"
  assert_contains "$OUT" "upgrade: deleted branch jig/upgrade-9.9.9 on origin"
  assert_eq task/elsewhere "$(git symbolic-ref --short HEAD)"
  assert_eq "$head" "$(git rev-parse HEAD)"
  assert_contains "$(git diff --name-only)" README.md
  [ -z "$(git stash list)" ] || fail "something was stashed"
  assert_eq "$(git rev-parse origin/main)" "$(git rev-parse main)"
  assert_contains "$(git show main:.ai/manifest)" "jig.version: 9.9.9"
  if git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9; then fail "the local branch is still here"; fi

  run jig upgrade --land
  assert_eq 0 "$RC"
  assert_contains "$OUT" "upgrade: no merged upgrade waits to be brought here"

  rm -rf "$LAND_REMOTE"
}

# A squash merge whose branch the forge already deleted: the local branch has
# no upstream left and `git branch -d` would measure it against HEAD, the
# task's branch. The merged head the forge reported lets it go anyway, also
# below agent.git push, where origin is never touched. The data says the
# checkout is not on the base.
test_upgrade_land_from_another_branch_after_a_squash_merge() {
  _land_project merged squash
  PATH=$LAND_PATH
  jig config set --local agent.git commit >/dev/null
  git push -q origin :refs/heads/jig/upgrade-9.9.9
  git fetch -q --prune origin
  git checkout -q -b task/elsewhere

  _up_json upgrade --land --json
  assert_eq 0 "$RC" "$ERR"
  assert_contains "$OUT" '"to":"9.9.9","outcome":"landed"'
  assert_contains "$OUT" '"commit":"'"$(git rev-parse origin/main)"'"'
  assert_contains "$OUT" '"land":{"base":"main","checkout_on_base":false,"branch_deleted":true,"origin_branch_deleted":false}'
  assert_contains "$ERR" "upgrade: deleted branch jig/upgrade-9.9.9"
  assert_eq task/elsewhere "$(git symbolic-ref --short HEAD)"
  assert_eq "$(git rev-parse origin/main)" "$(git rev-parse main)"
  if git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9; then fail "the local branch is still here"; fi

  rm -rf "$LAND_REMOTE"
}

# On a detached HEAD in a clone with no local main, main is created from
# origin's, tracking it; HEAD stays detached where it was.
test_upgrade_land_on_a_detached_head_creates_a_missing_base() {
  _land_project merged
  PATH=$LAND_PATH
  local head
  git checkout -q --detach
  head=$(git rev-parse HEAD)
  git branch -q -D main

  run jig upgrade --land
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "this checkout stays on a detached HEAD"
  assert_eq "$(git rev-parse origin/main)" "$(git rev-parse main)"
  assert_eq origin/main "$(git rev-parse --abbrev-ref "main@{upstream}")"
  assert_eq "$head" "$(git rev-parse HEAD)"
  if git symbolic-ref -q HEAD >/dev/null; then fail "HEAD was attached to a branch"; fi

  rm -rf "$LAND_REMOTE"
}

# A branch that has merged origin's main already has the upgrade: no `next:`
# line tells it to merge main again.
test_upgrade_land_from_a_branch_that_has_the_upgrade_says_no_next() {
  _land_project merged
  PATH=$LAND_PATH
  git checkout -q -b task/elsewhere
  git merge -q --ff-only origin/main

  run jig upgrade --land
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "this checkout stays on task/elsewhere"
  assert_not_contains "$OUT" "next:"
  assert_eq "$(git rev-parse origin/main)" "$(git rev-parse main)"

  rm -rf "$LAND_REMOTE"
}

# A main another worktree is rebasing shows there as a detached HEAD, so the
# checks pass; git itself refuses to move a branch in use, and nothing moves.
test_upgrade_land_from_another_branch_never_moves_a_base_being_rebased() {
  _land_project merged
  PATH=$LAND_PATH
  local wt main_before
  git checkout -q -b task/elsewhere
  wt=$(mktemp -d "${TMPDIR:-/tmp}/jig-land-wt.XXXXXX")
  rmdir "$wt"
  git worktree add -q "$wt" main
  ( cd "$wt" && GIT_SEQUENCE_EDITOR="sed -i.bak s/^pick/edit/" git rebase -q -i HEAD~1 >/dev/null 2>&1 ) || true
  git -C "$wt" status | grep -q "rebase in progress" || fail "the fixture is not rebasing"
  main_before=$(git rev-parse main)

  run jig upgrade --land
  assert_eq 1 "$RC" "$OUT"
  assert_contains "$OUT" "upgrade --land: main could not be fast-forwarded to origin/main (another worktree uses it, or it moved while this ran); nothing was changed"
  assert_eq "$main_before" "$(git rev-parse main)"
  assert_eq task/elsewhere "$(git symbolic-ref --short HEAD)"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the branch was deleted"

  git -C "$wt" rebase --abort >/dev/null 2>&1 || true
  git worktree remove --force "$wt"
  rm -rf "$LAND_REMOTE"
}

# A main another worktree is rebasing that already equals origin's needs no
# move: the landing does not ask git to move it, so git's refusal of a branch
# in use never stops it, and main stays where it is.
test_upgrade_land_from_another_branch_leaves_a_base_being_rebased_that_needs_no_move() {
  _land_project merged
  PATH=$LAND_PATH
  local wt
  git checkout -q -b task/elsewhere
  git branch -q -f main origin/main
  wt=$(mktemp -d "${TMPDIR:-/tmp}/jig-land-wt.XXXXXX")
  rmdir "$wt"
  git worktree add -q "$wt" main
  ( cd "$wt" && GIT_SEQUENCE_EDITOR="sed -i.bak s/^pick/edit/" git rebase -q -i HEAD~1 >/dev/null 2>&1 ) || true
  git -C "$wt" status | grep -q "rebase in progress" || fail "the fixture is not rebasing"

  run jig upgrade --land
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "upgrade: landed jig/upgrade-9.9.9 (https://github.com/example/example/pull/12); main at"
  assert_contains "$OUT" "this checkout stays on task/elsewhere"
  assert_not_contains "$OUT" "could not be fast-forwarded"
  assert_eq "$(git rev-parse origin/main)" "$(git rev-parse main)"
  assert_eq task/elsewhere "$(git symbolic-ref --short HEAD)"

  git -C "$wt" rebase --abort >/dev/null 2>&1 || true
  git worktree remove --force "$wt"
  rm -rf "$LAND_REMOTE"
}

# From another branch, main checked out in another worktree is that
# worktree's to move, and a main with a commit origin's lacks is never moved:
# both named at once, nothing moves.
test_upgrade_land_from_another_branch_keeps_the_refusals_that_protect() {
  _land_project merged
  PATH=$LAND_PATH
  local wt main_before
  git commit -q --allow-empty -m "local only"
  main_before=$(git rev-parse main)
  git checkout -q -b task/elsewhere
  wt=$(mktemp -d "${TMPDIR:-/tmp}/jig-land-wt.XXXXXX")
  rmdir "$wt"
  git worktree add -q "$wt" main

  run jig upgrade --land
  assert_eq 1 "$RC"
  assert_contains "$OUT" "main is checked out in another worktree; run \`jig upgrade --land\` there"
  assert_contains "$OUT" "main here has commits origin/main does not have, so it cannot be fast-forwarded"
  assert_eq "$main_before" "$(git rev-parse main)"
  assert_eq task/elsewhere "$(git symbolic-ref --short HEAD)"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the branch was deleted"

  git worktree remove --force "$wt"
  rm -rf "$LAND_REMOTE"
}

# On main itself the tree is moved, so uncommitted changes still stop it.
test_upgrade_land_on_the_base_refuses_a_dirty_tree() {
  _land_project merged
  PATH=$LAND_PATH
  local head
  printf 'work\n' >> README.md
  head=$(git rev-parse HEAD)

  _up_json upgrade --land --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"error":{"code":"upgrade-blocked","message":"upgrade --land: nothing was changed:\n  - the working tree has uncommitted changes'
  assert_eq "$head" "$(git rev-parse HEAD)"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the branch was deleted"

  rm -rf "$LAND_REMOTE"
}

# A main here with a commit origin's does not have cannot be fast-forwarded,
# and is never forced.
test_upgrade_land_refuses_a_base_that_cannot_be_fast_forwarded() {
  _land_project merged
  PATH=$LAND_PATH
  local head
  git commit -q --allow-empty -m "local only"
  head=$(git rev-parse HEAD)

  run jig upgrade --land
  assert_eq 1 "$RC"
  assert_contains "$OUT" "main here has commits origin/main does not have, so it cannot be fast-forwarded"
  assert_eq "$head" "$(git rev-parse HEAD)"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the branch was deleted"

  rm -rf "$LAND_REMOTE"
}

# The data a program gates its buttons on: the shape of `jig upgrade --json`,
# with what --land did beside it. Below agent.git push, origin is not touched.
test_upgrade_land_json_reports_a_landed_upgrade() {
  _land_project merged
  PATH=$LAND_PATH
  jig config set --local agent.git commit >/dev/null
  local from
  from=$(sed -n 's/^jig.version: //p' .ai/manifest)

  _up_json upgrade --land --json
  assert_eq 0 "$RC" "$ERR"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -c .)" "stdout held more than one line: $OUT"
  assert_contains "$OUT" '"data":{"mode":"copy","dry_run":false,"from":"'"$from"'","to":"9.9.9","outcome":"landed","files":null,"git":{"level":"commit","branch":"jig/upgrade-9.9.9","commit":"'"$(git rev-parse HEAD)"'","pushed":true,"pull_request":"https://github.com/example/example/pull/12","merged":true},"land":{"base":"main","checkout_on_base":true,"branch_deleted":true,"origin_branch_deleted":false},"manual_steps":[],"would_stop":[]}}'
  assert_contains "$ERR" "upgrade: landed jig/upgrade-9.9.9"
  git -C "$LAND_REMOTE" show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "origin's branch was deleted below agent.git push"

  _up_json upgrade --land --json
  assert_eq 0 "$RC" "$ERR"
  assert_contains "$OUT" '"outcome":"nothing-to-do","files":null,"git":null,"land":null'

  rm -rf "$LAND_REMOTE"
}

test_upgrade_land_takes_no_other_argument() {
  _unit_project
  _up_json upgrade --land --dry-run --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"error":{"code":"usage","message":"upgrade: --land takes no other argument: --dry-run"}'
}

# GitLab answers as a merge request, whose own web_url follows its author's.
# On GitHub the pull request is asked about under the clone's account: one gh
# does not hold is a refusal before anything is asked or changed.
test_upgrade_land_refuses_a_github_account_gh_does_not_hold() {
  local head_before
  _land_project merged
  PATH=$LAND_PATH
  git remote set-url origin https://github.com/example/example.git
  jig config set --local github.account dave >/dev/null
  head_before=$(git rev-parse HEAD)

  run jig upgrade --land
  assert_eq 1 "$RC" "$OUT"
  assert_contains "$OUT" "upgrade --land:"
  assert_contains "$OUT" "github.account is dave"
  assert_eq "$head_before" "$(git rev-parse HEAD)" "HEAD moved"
  assert_eq main "$(git symbolic-ref --short HEAD)"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the upgrade branch was let go"
  assert_eq "0" "$(grep -c '^pr list' stub-bin/calls || true)" "the forge was asked about pull requests"

  rm -rf "$LAND_REMOTE"
}

test_upgrade_land_asks_gitlab_for_the_merge_request() {
  _land_project merged "" gitlab
  PATH=$LAND_PATH

  run jig upgrade --land
  assert_eq 0 "$RC"
  assert_contains "$OUT" "upgrade: landed jig/upgrade-9.9.9 (https://gitlab.com/example/example/-/merge_requests/12)"
  assert_contains "$(cat stub-bin/calls)" "mr list --all --target-branch main"
  assert_eq "$(git rev-parse origin/main)" "$(git rev-parse HEAD)"

  rm -rf "$LAND_REMOTE"
}

# With git.delete_merged_branches false the upgrade still lands; its branch stays.
test_upgrade_land_keeps_the_branch_when_the_key_is_off() {
  _land_project merged
  PATH=$LAND_PATH
  jig config set --local git.delete_merged_branches false >/dev/null

  _up_json upgrade --land --json
  assert_eq 0 "$RC" "$ERR"
  assert_contains "$OUT" '"outcome":"landed"'
  assert_contains "$OUT" '"land":{"base":"main","checkout_on_base":true,"branch_deleted":false,"origin_branch_deleted":false}'
  assert_eq "$(git rev-parse origin/main)" "$(git rev-parse HEAD)"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the local branch was deleted"
  git -C "$LAND_REMOTE" show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "origin's branch was deleted"

  rm -rf "$LAND_REMOTE"
}

# On the upgrade branch with main checked out in another worktree, git could
# not switch here: refused, nothing moved.
test_upgrade_land_refuses_a_base_checked_out_elsewhere() {
  _land_project merged
  PATH=$LAND_PATH
  local wt
  git checkout -q jig/upgrade-9.9.9
  wt=$(mktemp -d "${TMPDIR:-/tmp}/jig-land-wt.XXXXXX")
  rmdir "$wt"
  git worktree add -q "$wt" main

  run jig upgrade --land
  assert_eq 1 "$RC"
  assert_contains "$OUT" "main is checked out in another worktree; run \`jig upgrade --land\` there"
  assert_eq jig/upgrade-9.9.9 "$(git symbolic-ref --short HEAD)"

  git worktree remove --force "$wt"
  rm -rf "$LAND_REMOTE"
}

# The forge says merged, but origin/main here does not have the upgrade (a
# fetch that failed only warns): nothing is called landed, the branch stays.
test_upgrade_land_refuses_an_origin_base_without_the_upgrade() {
  _land_project open
  PATH=$LAND_PATH
  local head
  sed 's/\tOPEN\t/\tMERGED\t/' stub-bin/prs > stub-bin/prs.new
  mv stub-bin/prs.new stub-bin/prs
  head=$(git rev-parse HEAD)

  _up_json upgrade --land --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"code":"upgrade-blocked"'
  assert_contains "$OUT" "origin/main here does not record Jig 9.9.9 yet"
  assert_eq "$head" "$(git rev-parse HEAD)"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the branch was deleted"

  rm -rf "$LAND_REMOTE"
}


# A return to a release: the base records unreleased code (`9.9.9+<sha>`) and
# the merged upgrade records `9.9.9`. An origin/main still at `9.9.9+<sha>` is
# the same release number, but not the upgrade, so nothing is called landed
# (task dev-channel-stays-out-of-projects, F7).
test_upgrade_land_refuses_an_origin_base_still_on_the_unreleased_build() {
  _land_project open
  PATH=$LAND_PATH
  local head
  # The base took unreleased code built on the release the branch returns to.
  sed 's/^jig\.version: .*/jig.version: 9.9.9+abc1234/' .ai/manifest > manifest.tmp
  mv manifest.tmp .ai/manifest
  git commit -q -am "took unreleased 9.9.9+abc1234"
  git push -q origin main
  git fetch -q origin
  sed 's/\tOPEN\t/\tMERGED\t/' stub-bin/prs > stub-bin/prs.new
  mv stub-bin/prs.new stub-bin/prs
  head=$(git rev-parse HEAD)

  _up_json upgrade --land --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"code":"upgrade-blocked"'
  assert_contains "$OUT" "origin/main here does not record Jig 9.9.9 yet"
  assert_eq "$head" "$(git rev-parse HEAD)"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the branch was deleted"

  rm -rf "$LAND_REMOTE"
}

# A glab that cannot answer is a forge that did not answer, never a list with
# no merge requests: nothing is called landed or nothing-to-do, nothing moves
# (task upgrade-land-followups, F4).
test_upgrade_land_says_so_when_glab_fails() {
  _land_project merged "" gitlab
  PATH=$LAND_PATH
  local head
  head=$(git rev-parse HEAD)
  cat > stub-bin/glab <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
esac
printf 'glab: could not reach gitlab.com\n' >&2
exit 1
STUB

  _up_json upgrade --land --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" "upgrade --land: the forge did not answer; nothing was changed"
  assert_not_contains "$OUT" "nothing-to-do"
  assert_eq "$head" "$(git rev-parse HEAD)"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the branch was deleted"

  rm -rf "$LAND_REMOTE"
}

# In a linked worktree on the upgrade's branch, with the base checked out
# nowhere, --land does not switch that worktree to the base, as jig_ship_leave
# never does: refused, nothing moved (task upgrade-land-followups, F5).
test_upgrade_land_never_switches_a_linked_worktree_to_the_base() {
  _land_project merged
  PATH=$LAND_PATH
  local wt here
  git checkout -q -b elsewhere
  wt=$(mktemp -d "${TMPDIR:-/tmp}/jig-land-wt.XXXXXX")
  rmdir "$wt"
  git worktree add -q "$wt" jig/upgrade-9.9.9

  here=$PWD
  cd "$wt"
  run jig upgrade --land
  cd "$here"
  # No refusal that asks for a switch: the worktree stays on its branch, the
  # base moves as a ref, and the branch waits for the worktree to leave it.
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "run \`jig upgrade --land\` in the main checkout"
  assert_contains "$OUT" "this checkout stays on jig/upgrade-9.9.9"
  assert_eq jig/upgrade-9.9.9 "$(git -C "$wt" symbolic-ref --short HEAD)"
  assert_eq "$(git rev-parse origin/main)" "$(git rev-parse main)"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the branch was deleted"

  git worktree remove --force "$wt"
  rm -rf "$LAND_REMOTE"
}

# --- unreleased sources (adr-20261106-copy-mode-projects-take-released-code-only) --

# _unreleased_declared — the version the running framework declares.
_unreleased_declared() {
  sed -n 's/^JIG_VERSION="\([^"]*\)".*/\1/p' "$JIG_HOME/scripts/lib/version.sh"
}

# _unit_unreleased_source <dir> — _unit_source's newer code (9.9.9), then one
# commit past its release tag: the version it names is 9.9.9+<sha>.
_unit_unreleased_source() {
  _mk_source_v2 "$1"
  printf '\n# past the tag\n' >> "$1/profiles/generic/verify.sh"
  git -C "$1" add -A
  git -C "$1" -c user.name=jig-tests -c user.email=tests@jig.invalid \
    commit -q --no-verify -m "past the tag"
}

test_upgrade_refuses_an_unreleased_source_and_changes_nothing() {
  _unit_project
  local src sha head
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-unrel.XXXXXX")
  src=$(cd "$src" && pwd)
  fixture_unreleased_source "$src"
  sha=$(git -C "$src" rev-parse --short=7 HEAD)
  head=$(git rev-parse HEAD)
  cp .ai/manifest manifest.before.tmp

  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "is not a release"
  assert_contains "$OUT" "--unreleased"
  assert_contains "$OUT" "+$sha"
  assert_eq "$head" "$(git rev-parse HEAD)"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"
  assert_eq "" "$(git branch --list 'jig/upgrade-*')" "a refused upgrade made a branch"
  assert_eq "" "$(git status --porcelain --untracked-files=no)" "a refused upgrade changed tracked files"
  diff -q manifest.before.tmp .ai/manifest >/dev/null || fail "the manifest changed"

  rm -rf "$src"
}

# A plan the real run would refuse is no plan.
test_upgrade_dry_run_refuses_an_unreleased_source_too() {
  _unit_project
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-unrel.XXXXXX")
  src=$(cd "$src" && pwd)
  fixture_unreleased_source "$src"

  run jig upgrade --from "$src" --dry-run
  assert_eq 1 "$RC"
  assert_contains "$OUT" "is not a release"
  assert_not_contains "$OUT" "dry run"

  rm -rf "$src"
}

test_upgrade_refuses_a_source_without_git() {
  _unit_project
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-nogit.XXXXXX")
  src=$(cd "$src" && pwd)
  cp -R "$JIG_HOME"/. "$src"/
  rm -rf "$src/.git"

  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "not a git checkout"
  assert_contains "$OUT" "+unknown"

  rm -rf "$src"
}

test_upgrade_json_refuses_an_unreleased_source_with_its_code() {
  _unit_project
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-unrel.XXXXXX")
  src=$(cd "$src" && pwd)
  fixture_unreleased_source "$src"

  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"code":"unreleased-source"'
  assert_eq "main" "$(git symbolic-ref --short HEAD)"

  rm -rf "$src"
}

test_upgrade_unreleased_takes_the_code_and_records_the_build() {
  _unit_project
  local src sha declared
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-unrel.XXXXXX")
  src=$(cd "$src" && pwd)
  fixture_unreleased_source "$src"
  sha=$(git -C "$src" rev-parse --short=7 HEAD)
  declared=$(_unreleased_declared)

  run jig upgrade --from "$src" --unreleased
  assert_eq 0 "$RC"
  assert_file_contains .ai/manifest "jig.version: $declared+$sha"
  # The branch is named for the release number, not the build.
  assert_contains "$OUT" "jig/upgrade-$declared"
  assert_not_contains "$OUT" "jig/upgrade-$declared+"

  rm -rf "$src"
}

test_upgrade_from_a_released_source_records_the_plain_version_again() {
  _unit_project
  local src sha declared
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-unrel.XXXXXX")
  src=$(cd "$src" && pwd)
  fixture_unreleased_source "$src"
  sha=$(git -C "$src" rev-parse --short=7 HEAD)
  declared=$(_unreleased_declared)

  run jig upgrade --from "$src" --unreleased
  assert_eq 0 "$RC"
  assert_file_contains .ai/manifest "jig.version: $declared+$sha"
  git add -A
  git commit -q -m "took unreleased code"

  # The released code replaces what the unreleased code changed, by hash, and
  # the manifest says it is the release again.
  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_file_contains .ai/manifest "jig.version: $declared"
  assert_not_contains "$(cat .ai/manifest)" "jig.version: $declared+"

  rm -rf "$src"
}

# Unreleased code whose framework files already equal a release's places
# nothing, yet the project is that release: the manifest says so.
test_upgrade_records_the_release_when_unreleased_code_already_matches_it() {
  fixture_repo
  local src declared
  declared=$(_unreleased_declared)
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-unrel.XXXXXX")
  src=$(cd "$src" && pwd)
  cp -R "$JIG_HOME"/. "$src"/
  printf '\nnot a framework file\n' >> "$src/README.md"
  git -C "$src" add -A
  git -C "$src" -c user.name=jig-tests -c user.email=tests@jig.invalid \
    commit -q --no-verify -m "past the tag, outside framework paths"

  run jig init --from "$src" --unreleased
  assert_eq 0 "$RC"
  assert_file_contains .ai/manifest "jig.version: $declared+"
  git add -A
  git commit -q -m "jig init from unreleased code"

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "manifest updated"
  assert_file_contains .ai/manifest "jig.version: $declared"
  assert_not_contains "$(cat .ai/manifest)" "jig.version: $declared+"

  rm -rf "$src"
}

# A released source with local changes is no release: a plain upgrade from it
# refuses, dry run included, and does not record the release's number; with
# --unreleased the project says it took a dirty build, and an upgrade from the
# clean release afterwards records the release again (task
# released-source-local-edits).
test_upgrade_refuses_a_release_tag_with_local_changes() {
  _unit_project
  local src head declared sha
  declared=$(_unreleased_declared)
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-dirty.XXXXXX")
  src=$(cd "$src" && pwd)
  cp -R "$JIG_HOME"/. "$src"/
  sha=$(git -C "$src" rev-parse --short=7 HEAD)
  printf '\n# edited at the tag\n' >> "$src/profiles/generic/verify.sh"
  head=$(git rev-parse HEAD)
  cp .ai/manifest manifest.before.tmp

  run jig upgrade --from "$src" --dry-run
  assert_eq 1 "$RC"
  assert_contains "$OUT" "at its release tag with uncommitted changes"

  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "at its release tag with uncommitted changes"
  assert_contains "$OUT" "--unreleased"
  assert_eq "$head" "$(git rev-parse HEAD)"
  diff -q manifest.before.tmp .ai/manifest >/dev/null || fail "the manifest changed"

  run jig upgrade --from "$src" --unreleased
  assert_eq 0 "$RC"
  assert_file_contains .ai/manifest "jig.version: $declared+$sha.dirty"
  git add -A
  git commit -q -m "took a dirty build"

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_file_contains .ai/manifest "jig.version: $declared"
  assert_not_contains "$(cat .ai/manifest)" "jig.version: $declared+"

  rm -rf "$src"
}

# The code running the upgrade is older than the unreleased source, so it hands
# the run to the source's own jig; that run must be told too, or it refuses what
# the first run was asked to take.
test_upgrade_unreleased_hands_off_to_newer_unreleased_code_with_the_flag() {
  _unit_project
  local src sha
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-unrel.XXXXXX")
  src=$(cd "$src" && pwd)
  _unit_unreleased_source "$src"
  sha=$(git -C "$src" rev-parse --short=7 HEAD)

  run jig upgrade --from "$src" --unreleased
  assert_eq 0 "$RC"
  assert_contains "$OUT" "handing the upgrade to 9.9.9"
  assert_not_contains "$OUT" "is not a release"
  assert_file_contains .ai/manifest "jig.version: 9.9.9+$sha"
  assert_contains "$OUT" "jig/upgrade-9.9.9"

  rm -rf "$src"
}

test_upgrade_without_the_flag_refuses_newer_unreleased_code_before_handing_off() {
  _unit_project
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-unrel.XXXXXX")
  src=$(cd "$src" && pwd)
  _unit_unreleased_source "$src"

  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "is not a release"
  assert_not_contains "$OUT" "handing the upgrade"
  assert_eq "main" "$(git symbolic-ref --short HEAD)"

  rm -rf "$src"
}

# Link mode runs the checkout itself, so what the checkout is does not matter.
test_upgrade_link_mode_does_not_refuse_an_unreleased_source() {
  skip_unless_symlinks
  fixture_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-unrel.XXXXXX")
  src=$(cd "$src" && pwd)
  fixture_unreleased_source "$src"
  jig init --from "$src" --link >/dev/null

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "is not a release"

  rm -rf "$src"
}

# upgrade_pending answers 4 — unknown for a named reason — and says nothing,
# so what asks it (verify, status, doctor) neither fails nor counts drift.
test_upgrade_pending_is_unknown_for_an_unreleased_source() {
  _unit_project
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-src-unrel.XXXXXX")
  src=$(cd "$src" && pwd)
  fixture_unreleased_source "$src"
  # The project's recorded source is now code no release contains.
  sed "s|^jig\\.source: .*|jig.source: $src|" .ai/manifest > manifest.tmp
  mv manifest.tmp .ai/manifest

  # shellcheck disable=SC2016 # expanded by the inner bash, not here
  # From the project's installed copy, which is no source root: the source is
  # then the one the manifest records.
  run env PATH="$(path_without_jig)" bash -c '
    set -u
    JIG_LIB="$PWD/.ai/scripts/lib"; export JIG_LIB
    . "$JIG_LIB/version.sh"; . "$JIG_LIB/common.sh"; . "$JIG_LIB/config.sh"
    jig_require_repo
    . "$JIG_LIB/upgrade.sh"
    rc=0; out=$(upgrade_pending) || rc=$?
    printf "rc=%s out=[%s]" "$rc" "$out"'
  assert_eq "rc=4 out=[]" "$OUT"

  rm -rf "$src"
}

# --- the upgrade in Jig's own tree, merged by Jig (upgrade.merge) ---------------

# _tree_gone — Jig's own tree and its lock are given back.
_tree_gone() {
  [ ! -e "$(git rev-parse --git-common-dir)/jig/tree" ] || fail "Jig's tree was left behind"
  [ ! -e .ai/runtime/writes/lock/busy/run ] || fail "the clone's lock was left behind"
}

# At agent.git pr and with nothing set, the upgrade merges its own pull request on
# green CI: built in Jig's tree, branch let go here and on origin, the base moved
# to origin's. The base is checked out here, so the new Jig arrives in the files.
test_upgrade_at_agent_git_pr_merges_itself_in_its_own_tree() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  local before
  before=$(git rev-parse main)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "upgrade: working on branch jig/upgrade-9.9.9, cut from main"
  assert_contains "$OUT" "upgrade: shipping at merge (upgrade.merge)"
  assert_contains "$OUT" "merged https://github.com/example/example/pull/7"
  assert_contains "$OUT" "upgrade: deleted branch jig/upgrade-9.9.9"
  assert_contains "$OUT" "upgrade: deleted branch jig/upgrade-9.9.9 on origin"
  assert_contains "$OUT" "upgrade: main here moved to"
  assert_not_contains "$OUT" "back on main"
  assert_eq main "$(git symbolic-ref --short HEAD)"
  assert_eq "$(git -C "$remote" rev-parse main)" "$(git rev-parse main)"
  [ "$before" != "$(git rev-parse main)" ] || fail "main did not move"
  assert_file_contains .ai/manifest "jig.version: 9.9.9"
  if git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9; then fail "the local branch is still here"; fi
  if git -C "$remote" show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9; then fail "the branch is still on origin"; fi
  _tree_gone
  # The merge is in the forge cache at once.
  assert_contains "$(cat .ai/runtime/forge-cache)" "jig/upgrade-9.9.9"
  assert_contains "$(cat .ai/runtime/forge-cache)" "merged"

  rm -rf "$src" "$remote"
}

# agent.git left unset: upgrade.merge agent is the upgrade's own right.
test_upgrade_merges_itself_without_agent_git_set() {
  local src remote
  remote=$(_upgrade_merge_project none)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "merged https://github.com/example/example/pull/7"
  assert_file_contains .ai/manifest "jig.version: 9.9.9"
  assert_eq "$(git -C "$remote" rev-parse main)" "$(git rev-parse main)"

  rm -rf "$src" "$remote"
}

# upgrade.merge human: each step goes by agent.git, and Jig never merges, even at
# merge. The pull request is open and the checkout is where it was.
test_upgrade_merge_human_opens_the_pull_request_and_does_not_merge() {
  local src remote
  remote=$(_upgrade_merge_project merge)
  PATH="$PWD/stub-bin:$PATH"
  jig config set --local upgrade.merge human >/dev/null
  src=$(_unit_source)
  local before
  before=$(git rev-parse main)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "upgrade: shipping at merge (agent.git)"
  assert_contains "$OUT" "pr https://github.com/example/example/pull/7"
  assert_not_contains "$OUT" "merged https://"
  assert_contains "$OUT" "next: this upgrade is on branch jig/upgrade-9.9.9"
  assert_no_file stub-bin/merged
  assert_eq "$before" "$(git rev-parse main)"
  assert_eq main "$(git symbolic-ref --short HEAD)"
  git -C "$remote" show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the branch did not reach origin"
  _tree_gone
  assert_contains "$(cat .ai/runtime/forge-cache)" "open"

  rm -rf "$src" "$remote"
}

# upgrade.merge human at pr stops at the pull request; at push, at the push.
test_upgrade_merge_human_follows_agent_git_push() {
  local src remote
  remote=$(_upgrade_merge_project push)
  PATH="$PWD/stub-bin:$PATH"
  jig config set --local upgrade.merge human >/dev/null
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "pushed jig/upgrade-9.9.9"
  assert_not_contains "$OUT" "pr https://"
  assert_contains "$OUT" "the pull request is yours"
  _tree_gone

  rm -rf "$src" "$remote"
}

# An invalid upgrade.merge reads as human: a mistake never merges.
test_upgrade_invalid_merge_key_does_not_merge() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  printf 'upgrade.merge: sometimes\n' >> .ai/config.local.yaml
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "pr https://github.com/example/example/pull/7"
  assert_not_contains "$OUT" "merged https://"
  assert_no_file stub-bin/merged

  rm -rf "$src" "$remote"
}

# The reported case (lure): a dirty checkout on a task's branch. The upgrade does
# not ask about it, changes none of it, and still lands: the base here moves as a
# ref, and the branch is told it takes the new Jig when it merges the base.
test_upgrade_leaves_a_dirty_checkout_on_a_task_branch_alone() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  git checkout -q -b task/elsewhere
  printf 'work in progress\n' >> README.md
  local readme head
  readme=$(cat README.md)
  head=$(git rev-parse HEAD)
  local before
  before=$(git rev-parse main)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "merged https://github.com/example/example/pull/7"
  assert_eq task/elsewhere "$(git symbolic-ref --short HEAD)"
  assert_eq "$head" "$(git rev-parse HEAD)"
  assert_eq "$readme" "$(cat README.md)"
  assert_file_contains .ai/manifest "jig.version: 0."
  assert_no_file .ai/skills/jig-newthing
  [ "$before" != "$(git rev-parse main)" ] || fail "the base did not move"
  assert_eq "$(git -C "$remote" rev-parse main)" "$(git rev-parse main)"
  assert_contains "$OUT" "next: task/elsewhere is still on Jig"
  assert_contains "$OUT" "git merge main"
  _tree_gone

  # A dry run of the same says nothing would stop it: Jig's tree asks nothing
  # of the checkout.
  _up_json upgrade --dry-run --from "$src" --json
  assert_contains "$OUT" '"would_stop":[]'

  rm -rf "$src" "$remote"
}

# Without an origin there is no tree: the upgrade works in the checkout as it
# always did, with its refusals, and a dry run says so.
test_upgrade_without_origin_still_refuses_a_dirty_checkout() {
  _unit_project
  jig config set --local agent.git pr >/dev/null
  local src
  src=$(_unit_source)
  printf '\n# local edit\n' >> README.md

  _up_json upgrade --dry-run --from "$src" --json
  assert_contains "$OUT" "the working tree has uncommitted changes"
  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "uncommitted changes"

  rm -rf "$src"
}

# The telescope case: the checkout stands on an older version's upgrade branch.
# The new upgrade is cut from the base, never staged on that branch; the old one
# is named as superseded, and neither deleted nor switched away from.
test_upgrade_does_not_continue_an_older_versions_branch() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  git checkout -q -b jig/upgrade-0.41.0
  printf 'human commit\n' > human.txt
  git add human.txt
  git commit -q -m "a commit of a person on an old upgrade branch"
  git push -q origin jig/upgrade-0.41.0
  local old
  old=$(git rev-parse HEAD)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "working on branch jig/upgrade-9.9.9, cut from main"
  assert_contains "$OUT" "merged https://github.com/example/example/pull/7"
  assert_contains "$OUT" "note: jig/upgrade-0.41.0 (here, origin) is superseded"
  assert_contains "$OUT" "next: jig/upgrade-0.41.0 is an older upgrade branch and is no longer needed; \`git checkout main\`"
  assert_eq jig/upgrade-0.41.0 "$(git symbolic-ref --short HEAD)"
  assert_eq "$old" "$(git rev-parse HEAD)"
  assert_file human.txt
  git -C "$remote" show-ref --verify --quiet refs/heads/jig/upgrade-0.41.0 || fail "the old branch was deleted on origin"

  _up_json upgrade --dry-run --from "$src" --json
  assert_contains "$OUT" '"would_stop":[]'

  rm -rf "$src" "$remote"
}

# The same rule in the checkout's own path: a repeat stays only on the branch of
# this very version.
test_upgrade_in_the_checkout_does_not_stay_on_another_versions_branch() {
  _unit_project
  jig config set --local agent.git commit >/dev/null
  local src
  src=$(_unit_source)
  git checkout -q -b jig/upgrade-0.41.0

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "working on branch jig/upgrade-9.9.9, cut from main"
  assert_eq jig/upgrade-9.9.9 "$(git symbolic-ref --short HEAD)"
  assert_eq "0" "$(git rev-list --count jig/upgrade-0.41.0..HEAD~1 2>/dev/null || printf 0)"

  rm -rf "$src"
}

# CI that is red, absent or unfinished leaves the pull request open: `not merged`,
# its code in --json, the row `open` in the cache, nothing held.
test_upgrade_not_merged_says_why_and_keeps_the_pull_request_open() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  printf 'fail\n' > stub-bin/checks

  _up_json upgrade --from "$src" --json
  assert_eq 0 "$RC"
  assert_contains "$ERR" "not merged: a check failed"
  assert_contains "$OUT" '"merged":false'
  assert_contains "$OUT" '"not_merged":{"code":"ci-red","reason":"a check failed"}'
  assert_contains "$OUT" '"merge_by":"agent"'
  assert_contains "$OUT" '"level_key":"upgrade.merge"'
  assert_contains "$OUT" '"base":null'
  assert_contains "$(cat .ai/runtime/forge-cache)" "open"
  assert_contains "$ERR" "Run \`jig upgrade\` again to carry it on"
  git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the local branch was deleted"
  _tree_gone

  # No checks at all: CI checked nothing.
  : > stub-bin/checks
  git branch -q -D jig/upgrade-9.9.9
  git push -q origin :refs/heads/jig/upgrade-9.9.9
  _up_json upgrade --from "$src" --json
  assert_contains "$OUT" '"code":"ci-none"'

  rm -rf "$src" "$remote"
}

# A repeat after `not merged` carries the pull request on: the open one is found,
# CI is waited for again, and it merges.
test_upgrade_repeat_carries_an_unmerged_upgrade_on() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  printf 'pending\n' > stub-bin/checks

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "not merged: the checks did not finish within 0 minutes"
  assert_no_file stub-bin/merged
  local tip
  tip=$(git rev-parse refs/heads/jig/upgrade-9.9.9)

  printf 'pass\n' > stub-bin/checks
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "the upgrade to 9.9.9 is already on branch jig/upgrade-9.9.9; carrying it on"
  assert_contains "$OUT" "merged https://github.com/example/example/pull/7"
  assert_contains "$(cat stub-bin/merged)" "--match-head-commit $tip"
  if git show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9; then fail "the local branch is still here"; fi
  assert_eq "$(git -C "$remote" rev-parse main)" "$(git rev-parse main)"
  _tree_gone

  rm -rf "$src" "$remote"
}

# A branch that carries a commit Jig did not write is not pushed or merged for the
# upgrade's own right: `branch-has-other-commits`, nothing sent. The person's own
# agent.git merge is the grant that covers it.
test_upgrade_repeat_does_not_send_what_is_not_jigs() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  git branch jig/upgrade-9.9.9 main
  git checkout -q jig/upgrade-9.9.9
  printf 'mine\n' > mine.txt
  git add mine.txt
  git commit -q -m "my own work"
  git checkout -q main

  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"code":"branch-has-other-commits"'
  assert_contains "$OUT" "jig/upgrade-9.9.9 carries commits Jig did not write"
  assert_no_file stub-bin/merged
  if git -C "$remote" show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9; then fail "a commit that is not Jig's was pushed"; fi
  _tree_gone

  # At the person's own agent.git merge, the grant is there.
  jig config set --local agent.git merge >/dev/null
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "merged https://github.com/example/example/pull/7"

  rm -rf "$src" "$remote"
}

# A commit that borrows the subject, or touches a file of the person's, is not Jig's;
# nor is one already on origin: origin holding the tip exempts the push, not the merge.
test_upgrade_repeat_judges_authorship_not_the_subject_or_origin() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  git branch jig/upgrade-9.9.9 main
  git checkout -q jig/upgrade-9.9.9
  printf 'mine\n' > mine.txt
  git add mine.txt
  git commit -q -m "Upgrade Jig 0.1.0 -> 9.9.9"
  git push -q origin jig/upgrade-9.9.9
  git checkout -q main

  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"code":"branch-has-other-commits"'
  assert_no_file stub-bin/merged

  rm -rf "$src" "$remote"
}

# A second clone upgrading while the first one's pull request waits does not cut the
# same name: origin's name is read, and the waiting upgrade is carried on from here.
test_upgrade_reads_origins_branch_names_for_a_second_clone() {
  local src remote two
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  printf 'pending\n' > stub-bin/checks
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "not merged: the checks did not finish"
  git -C "$remote" show-ref --verify --quiet refs/heads/jig/upgrade-9.9.9 || fail "the branch is not on origin"

  two=$(mktemp -d "${TMPDIR:-/tmp}/jig-clone2.XXXXXX")
  rm -rf "$two"
  git clone -q -b main "$remote" "$two"
  printf 'pass\n' > stub-bin/checks
  cd "$two"
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "the upgrade to 9.9.9 is already on branch jig/upgrade-9.9.9; carrying it on"
  assert_contains "$OUT" "merged https://github.com/example/example/pull/7"
  [ -z "$(git branch --list 'jig/upgrade-9.9.9-*')" ] || fail "a second name was cut"

  rm -rf "$src" "$remote" "$two"
}

# A framework path the project gitignores could not travel in a commit made in Jig's
# tree: the run says so and works in the checkout, as an ordinary in-checkout upgrade
# (commit, the ignored file placed, a second run has nothing to do), and says so in
# --json. A dry run and `jig status` on such a project change nothing.
test_upgrade_works_in_the_checkout_when_the_project_ignores_a_framework_path() {
  local src remote head
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  printf '.codex/skills/jig-newthing/\n' >> .gitignore
  git add .gitignore
  git commit -q -m "ignore a path"
  git push -q origin main
  jig config set --local upgrade.merge human >/dev/null
  src=$(_unit_source)
  head=$(git rev-parse HEAD)
  git checkout -q -b task/x
  local before_branches
  before_branches=$(git branch --list | tr -d ' *')

  # Read-only: a dry run and the reads that ask it.
  _up_json upgrade --dry-run --from "$src" --json
  assert_eq 0 "$RC" "$ERR"
  assert_contains "$ERR" "a real upgrade would work in your checkout, not in Jig's tree"
  assert_eq task/x "$(git symbolic-ref --short HEAD)"
  run jig status
  assert_eq task/x "$(git symbolic-ref --short HEAD)"
  assert_eq "$before_branches" "$(git branch --list | tr -d ' *')"
  assert_no_file .codex/skills/jig-newthing/SKILL.md
  _tree_gone

  git checkout -q main
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "note: this project's .gitignore ignores framework files the upgrade places (.codex/skills/jig-newthing/SKILL.md)"
  assert_contains "$OUT" "working on branch jig/upgrade-9.9.9, cut from main"
  assert_not_contains "$OUT" "shipping at merge"
  assert_not_contains "$OUT" "not committed"
  # upgrade.merge human: the pull request is opened and never merged here.
  assert_not_contains "$OUT" "merged https://"
  assert_no_file stub-bin/merged
  assert_file .codex/skills/jig-newthing/SKILL.md
  [ "$head" != "$(git rev-parse jig/upgrade-9.9.9)" ] || fail "nothing was committed"
  _tree_gone

  # An ordinary in-checkout upgrade waiting for its merge: a rerun is the usual refusal.
  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "has not been merged into main yet"
  assert_not_contains "$OUT" "not committed"

  rm -rf "$src" "$remote"
}

# upgrade.merge agent, agent.git merge, same project: the checkout path merges (the
# person's own grant), and --json says where it worked and why.
test_upgrade_ignored_path_fallback_reports_itself_in_json() {
  local src remote
  remote=$(_upgrade_merge_project merge)
  PATH="$PWD/stub-bin:$PATH"
  printf '.codex/skills/jig-newthing/\n' >> .gitignore
  git add .gitignore
  git commit -q -m "ignore a path"
  git push -q origin main
  src=$(_unit_source)

  _up_json upgrade --from "$src" --json
  assert_eq 0 "$RC" "$ERR"
  assert_contains "$OUT" '"level":"merge"'
  assert_contains "$OUT" '"level_key":"agent.git","path":"checkout","ignored":[".codex/skills/jig-newthing/SKILL.md"],"fell_back":"gitignored"'
  assert_contains "$OUT" '"merged":true'
  assert_file .codex/skills/jig-newthing/SKILL.md

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "nothing changed"

  rm -rf "$src" "$remote"
}

# upgrade.merge human never merges on the ignored-path fallback either, even at agent.git
# merge: --json says the run worked in the checkout and left the merge to a human.
test_upgrade_merge_human_never_merges_on_the_ignored_path_fallback() {
  local src remote
  remote=$(_upgrade_merge_project merge)
  PATH="$PWD/stub-bin:$PATH"
  printf '.codex/skills/jig-newthing/\n' >> .gitignore
  git add .gitignore
  git commit -q -m "ignore a path"
  git push -q origin main
  jig config set --local upgrade.merge human >/dev/null
  src=$(_unit_source)

  _up_json upgrade --from "$src" --json
  assert_eq 0 "$RC" "$ERR"
  assert_contains "$OUT" '"path":"checkout"'
  assert_contains "$OUT" '"merge_by":"human"'
  assert_contains "$OUT" '"merged":false'
  assert_no_file stub-bin/merged
  assert_file .codex/skills/jig-newthing/SKILL.md

  rm -rf "$src" "$remote"
}

# A repeat that carries on an upgrade branch already waiting works on that branch and
# touches nothing in the checkout, so --json reports the tree path with no ignored paths.
test_upgrade_carry_on_reports_the_tree_path() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  printf '.codex/skills/jig-newthing/\n' >> .gitignore
  git add .gitignore
  git commit -q -m "ignore a path"
  git push -q origin main
  src=$(_unit_source)

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_no_file stub-bin/merged
  git checkout -q main

  _up_json upgrade --from "$src" --json
  assert_eq 0 "$RC" "$ERR"
  assert_contains "$OUT" '"path":"tree","ignored":[],"fell_back":null'

  rm -rf "$src" "$remote"
}

# upgrade.merge human never merges, on the in-checkout path either, even at agent.git merge.
test_upgrade_merge_human_never_merges_in_the_checkout() {
  _unit_project
  local src remote
  remote=$(mktemp -d "${TMPDIR:-/tmp}/jig-remote.XXXXXX")
  git init -q --bare "$remote"
  git remote add origin "$remote"
  git push -q origin main
  jig config set --local agent.git merge upgrade.merge human >/dev/null
  src=$(_unit_source)
  mkdir -p stub-bin
  # shellcheck disable=SC2016 # the stub expands its own arguments
  printf '#!/bin/sh\ncase "$1 $2" in "auth status") exit 0 ;; "pr list") echo null ;; "pr create") echo https://github.com/example/example/pull/7 ;; *) echo "UNEXPECTED $*" >> "%s/stub-bin/calls" ;; esac\n' "$PWD" > stub-bin/gh
  chmod +x stub-bin/gh
  printf 'stub-bin/\n' >> .git/info/exclude
  sed 's|^forge:.*|forge: github|' .ai/config.yaml > c.tmp && mv c.tmp .ai/config.yaml
  git commit -q -am "github"
  PATH="$PWD/stub-bin:$PATH"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "merged https://"
  assert_no_file stub-bin/calls

  rm -rf "$src" "$remote"
}

# A branch only origin holds, with commits that are not Jig's, is refused without
# making a local branch of it.
test_upgrade_refusal_for_an_origin_only_branch_leaves_no_local_branch() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  git branch jig/upgrade-9.9.9 main
  git checkout -q jig/upgrade-9.9.9
  printf 'mine\n' > mine.txt
  git add mine.txt
  git commit -q -m "my own work"
  git push -q origin jig/upgrade-9.9.9
  git checkout -q main
  git branch -q -D jig/upgrade-9.9.9

  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"code":"branch-has-other-commits"'
  [ -z "$(git branch --list 'jig/upgrade-*')" ] || fail "a local branch was made from origin's"
  assert_no_file stub-bin/merged

  rm -rf "$src" "$remote"
}

# Under upgrade.merge human the unmerged branch is the refusal it always was.
test_upgrade_merge_human_still_refuses_an_unmerged_branch() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  jig config set --local upgrade.merge human >/dev/null
  src=$(_unit_source)
  git branch jig/upgrade-9.9.9 main
  git commit -q --allow-empty -m "x"
  git checkout -q jig/upgrade-9.9.9
  git commit -q --allow-empty -m "Upgrade Jig 0 -> 9.9.9"
  git checkout -q main

  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "is already on branch jig/upgrade-9.9.9, which has not been merged into main yet"

  rm -rf "$src" "$remote"
}

# A pre-commit hook that needs the project's installed dependencies fails in Jig's tree,
# which has none: the run gives the tree back, says so (without quoting the hook), and does
# the whole upgrade in the checkout, where the hook passes; --json reports why.
test_upgrade_pre_commit_hook_refusal_falls_back_to_the_checkout() {
  local src remote head
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  jig config set --local upgrade.merge human >/dev/null
  src=$(_unit_source)
  head=$(git rev-parse HEAD)
  mkdir -p .git/hooks node_modules
  printf 'node_modules/\n' >> .git/info/exclude
  : > node_modules/ok
  printf '#!/bin/sh\n[ -f node_modules/ok ] || { echo "lint needs the project dependencies" >&2; exit 1; }\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit

  _up_json upgrade --from "$src" --json
  assert_eq 0 "$RC" "$ERR"
  assert_contains "$ERR" "note: the project's pre-commit hook refused the commit in Jig's tree, which has none of the project's installed dependencies; the upgrade works in your checkout instead, where it has them"
  assert_not_contains "$ERR" "lint needs the project dependencies"
  assert_not_contains "$OUT" "lint needs the project dependencies"
  assert_contains "$OUT" '"path":"checkout","ignored":[],"fell_back":"pre-commit-hook"'
  assert_contains "$OUT" '"branch":"jig/upgrade-9.9.9"'
  _tree_gone
  if git worktree list | grep -q 'jig/tree'; then fail "git still lists Jig's tree"; fi
  [ "$head" != "$(git rev-parse jig/upgrade-9.9.9)" ] || fail "nothing was committed on the branch"
  assert_eq "Upgrade Jig" "$(git log -1 --format=%s jig/upgrade-9.9.9 | cut -c1-11)"
  assert_eq "" "$(git status --porcelain | grep -v '^??' || true)"

  rm -rf "$src" "$remote"
}

# The fall-back ships at agent.git, not at upgrade.merge's level: with the default
# upgrade.merge agent and agent.git none, the change is left staged on the branch in the
# checkout — nothing pushed, no pull request, nothing merged.
test_upgrade_pre_commit_hook_fallback_ships_at_agent_git() {
  local src remote
  remote=$(_upgrade_merge_project none)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  mkdir -p .git/hooks node_modules
  printf 'node_modules/\n' >> .git/info/exclude
  : > node_modules/ok
  printf '#!/bin/sh\n[ -f node_modules/ok ] || { echo "lint needs the project dependencies" >&2; exit 1; }\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit

  _up_json upgrade --from "$src" --json
  assert_eq 0 "$RC" "$ERR"
  assert_contains "$OUT" '"outcome":"staged"'
  assert_contains "$OUT" '"level":"none"'
  assert_contains "$OUT" '"level_key":"agent.git","path":"checkout","ignored":[],"fell_back":"pre-commit-hook","merge_by":"agent"'
  assert_contains "$OUT" '"pushed":false'
  assert_contains "$OUT" '"merged":false'
  assert_eq jig/upgrade-9.9.9 "$(git symbolic-ref --short HEAD)"
  [ -n "$(git diff --cached --name-only)" ] || fail "the upgrade was not left staged"
  if git ls-remote --heads "$remote" | grep -q 'jig/upgrade'; then fail "the branch was pushed"; fi
  assert_no_file stub-bin/merged
  _tree_gone

  rm -rf "$src" "$remote"
}

# The hook refuses in the checkout as well: the in-checkout behaviour applies as it is —
# the commit fails, and the branch with the staged upgrade stays for a repeat to finish.
test_upgrade_pre_commit_hook_refusing_in_the_checkout_too_leaves_the_branch() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  mkdir -p .git/hooks
  printf '#!/bin/sh\necho "hook says no" >&2\nexit 1\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit

  run jig upgrade --from "$src"
  [ "$RC" != 0 ] || fail "the upgrade should have failed"
  assert_contains "$OUT" "the upgrade works in your checkout instead"
  assert_contains "$OUT" "git commit failed"
  assert_eq jig/upgrade-9.9.9 "$(git symbolic-ref --short HEAD)"
  _tree_gone
  assert_no_file stub-bin/merged

  rm -rf "$src" "$remote"
}

# The hook refuses in Jig's tree and the checkout is busy: the checkout preflight stops the
# run, and nothing is touched there.
test_upgrade_pre_commit_hook_fallback_stops_on_a_busy_checkout() {
  local src remote head
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  mkdir -p .git/hooks
  printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  printf 'work\n' >> .gitignore
  head=$(git rev-parse HEAD)

  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"code":"upgrade-blocked"'
  assert_contains "$OUT" "the working tree has uncommitted changes"
  assert_eq "$head" "$(git rev-parse HEAD)"
  assert_eq main "$(git symbolic-ref --short HEAD)"
  assert_contains "$(git status --porcelain)" " M .gitignore"
  [ -z "$(git branch --list 'jig/upgrade-*')" ] || fail "a branch was left behind"
  _tree_gone

  rm -rf "$src" "$remote"
}

# Git refuses the commit in Jig's tree with no pre-commit hook in the project: still
# commit-refused, nothing left behind, the checkout untouched.
test_upgrade_commit_refused_without_a_hook_stays_commit_refused() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  git config commit.gpgsign true
  git config gpg.program false

  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"code":"commit-refused"'
  assert_contains "$OUT" "not committed: git refused the commit in Jig's tree: "
  [ -z "$(git branch --list 'jig/upgrade-*')" ] || fail "a branch was left behind"
  _tree_gone
  assert_eq main "$(git symbolic-ref --short HEAD)"
  assert_eq "" "$(git status --porcelain | grep -v '^??' || true)"

  rm -rf "$src" "$remote"
}

# A write that holds the clone's lock keeps the upgrade out, as it keeps another
# write: write-busy, and nothing is changed.
test_upgrade_refuses_while_a_write_holds_the_lock() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  mkdir -p .ai/runtime/writes/lock/busy
  printf 'checkout: %s\npid: %s\n' "$PWD" "$$" > .ai/runtime/writes/lock/busy/run

  _up_json upgrade --from "$src" --json
  assert_eq 1 "$RC"
  assert_contains "$OUT" '"code":"write-busy"'
  [ -z "$(git branch --list 'jig/upgrade-*')" ] || fail "a branch was cut"
  assert_file .ai/runtime/writes/lock/busy/run

  rm -rf "$src" "$remote"
}

# A `jig verify` running in the checkout that stands on the base: the base is not
# moved under it, and the run says how to move it later. The merge is made.
test_upgrade_does_not_move_a_base_under_a_running_verify() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  mkdir -p .ai/runtime/verify/busy
  printf 'checkout: %s\npid: %s\n' "$PWD" "$$" > .ai/runtime/verify/busy/run
  local before
  before=$(git rev-parse main)

  _up_json upgrade --from "$src" --json
  assert_eq 0 "$RC"
  assert_contains "$ERR" "merged https://github.com/example/example/pull/7"
  assert_contains "$ERR" "next: main here has not moved, because \`jig verify\` is running in this checkout"
  assert_contains "$OUT" '"base":"verify-running"'
  assert_eq "$before" "$(git rev-parse main)"
  assert_eq "$(git -C "$remote" rev-parse main)" "$(git rev-parse origin/main)"

  rm -rf "$src" "$remote"
}

# A base checked out in another worktree is not moved from here.
test_upgrade_does_not_move_a_base_checked_out_in_another_worktree() {
  local src remote
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  src=$(_unit_source)
  git checkout -q -b task/elsewhere
  local wt
  wt=$(mktemp -d "${TMPDIR:-/tmp}/jig-wt.XXXXXX")
  rm -rf "$wt"
  git worktree add -q "$wt" main

  _up_json upgrade --from "$src" --json
  assert_eq 0 "$RC"
  assert_contains "$OUT" '"base":"checked-out-elsewhere"'
  assert_contains "$ERR" "next: main here has not moved"

  git worktree remove --force "$wt"
  rm -rf "$src" "$remote"
}

# `--land` run by a project's older copy goes to the newer jig on this machine,
# which brings the upgrade here without asking for a switch (jig-ui, 0.45.0).
test_upgrade_land_is_handed_to_a_newer_global_jig() {
  _unit_project
  local global path
  global=$(_unit_source)
  printf '\nprintf "NEW-DISPATCHER\\n" >&2\n' >> "$global/scripts/lib/version.sh"
  fixture_release_source "$global"
  global=$(cd "$global" && pwd -P)
  path=$(_upgrade_global_path "$global")

  run env PATH="$path" bash "$JIG_HOME/scripts/jig" upgrade --land
  assert_contains "$OUT" "NEW-DISPATCHER"
  assert_contains "$OUT" "handing --land to 9.9.9 from $global"

  # Not newer: no hand-off.
  _unbump_source "$global"
  run env PATH="$path" bash "$JIG_HOME/scripts/jig" upgrade --land
  assert_not_contains "$OUT" "NEW-DISPATCHER"

  rm -rf "$global"
}

# Run in the loop the hand-off guards against: a handed-off run goes on where it is.
test_upgrade_land_handed_off_does_not_loop() {
  _unit_project
  local global path
  global=$(_unit_source)
  global=$(cd "$global" && pwd -P)
  path=$(_upgrade_global_path "$global")

  run env PATH="$path" JIG_UPGRADE_HANDED_OFF=0.0.1 bash "$JIG_HOME/scripts/jig" upgrade --land
  assert_not_contains "$OUT" "handing"

  rm -rf "$global"
}

# Nothing to change: the tree is given back, no branch is cut anywhere, and the
# checkout is as it was; from another branch, the way forward is the base.
test_upgrade_in_its_own_tree_with_nothing_to_change_leaves_nothing() {
  local remote head
  remote=$(_upgrade_merge_project pr)
  PATH="$PWD/stub-bin:$PATH"
  head=$(git rev-parse HEAD)

  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "upgrade: nothing changed"
  assert_not_contains "$OUT" "shipping at"
  [ -z "$(git branch --list 'jig/upgrade-*')" ] || fail "a branch was cut here"
  [ -z "$(git -C "$remote" branch --list 'jig/upgrade-*')" ] || fail "a branch reached origin"
  _tree_gone
  assert_eq "$head" "$(git rev-parse HEAD)"
  assert_eq main "$(git symbolic-ref --short HEAD)"
  assert_no_file stub-bin/merged

  git checkout -q -b task/behind
  run jig upgrade --from "$JIG_HOME"
  assert_eq 0 "$RC"
  assert_contains "$OUT" "upgrade: nothing changed"
  assert_contains "$OUT" "next: main already has this version"
  assert_contains "$OUT" "git merge main"
  assert_eq task/behind "$(git symbolic-ref --short HEAD)"
  _tree_gone

  rm -rf "$remote"
}

# --- profile stacks (extends) ---------------------------------------------------

# _stack_source <dest> — a released copy of $JIG_HOME that ships two more stock
# profiles: `zbase`, with a verify.sh, and `ztop`, a layer over it that is a
# profile.yaml and nothing else.
_stack_source() {
  local dest="$1"
  cp -R "$JIG_HOME"/. "$dest"/
  mkdir -p "$dest/profiles/zbase" "$dest/profiles/ztop"
  printf 'name: zbase\ndescription: fixture base.\n' > "$dest/profiles/zbase/profile.yaml"
  printf '#!/usr/bin/env bash\necho "zbase: own: pass"\nexit 0\n' > "$dest/profiles/zbase/verify.sh"
  printf 'name: ztop\nextends: zbase\n' > "$dest/profiles/ztop/profile.yaml"
  fixture_release_source "$dest"
}

test_upgrade_installs_the_base_of_a_listed_layer_and_leaves_profiles_alone() {
  fixture_repo
  jig init --from "$JIG_HOME" --profiles generic >/dev/null
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-stack-src.XXXXXX")
  _stack_source "$src"
  printf 'profiles: [generic, ztop]\nadapters: [claude, codex]\n' > .ai/config.yaml

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_file .ai/profiles/ztop/profile.yaml
  assert_file .ai/profiles/zbase/profile.yaml
  assert_file .ai/profiles/zbase/verify.sh
  assert_file_contains .ai/manifest ".ai/profiles/zbase/verify.sh"
  # Upgrade installs the stack; it never writes the list.
  assert_file_contains .ai/config.yaml "profiles: \[generic, ztop\]"

  rm -rf "$src"
}

test_upgrade_does_not_delete_a_base_the_manifest_remembers() {
  fixture_repo
  jig init --from "$JIG_HOME" --profiles generic >/dev/null
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-stack-src.XXXXXX")
  _stack_source "$src"
  printf 'profiles: [generic, ztop]\nadapters: [claude, codex]\n' > .ai/config.yaml
  run jig upgrade --from "$src"
  assert_eq 0 "$RC"

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "remove .ai/profiles/zbase"
  assert_file .ai/profiles/zbase/verify.sh
  assert_file_contains .ai/manifest ".ai/profiles/zbase/verify.sh"

  rm -rf "$src"
}

test_upgrade_refuses_a_stack_that_does_not_resolve_before_placing_a_file_copy_mode() {
  fixture_repo
  jig init --from "$JIG_HOME" --profiles generic >/dev/null
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-stack-src.XXXXXX")
  _stack_source "$src"
  printf 'name: ztop\nextends: ghost\n' > "$src/profiles/ztop/profile.yaml"
  fixture_release_source "$src"
  printf 'profiles: [generic, ztop]\nadapters: [claude, codex]\n' > .ai/config.yaml
  cp .ai/manifest manifest.before.tmp

  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "ztop: extends 'ghost', which is neither shipped with jig nor in .ai/profiles"
  assert_contains "$OUT" "Nothing was changed"
  assert_no_file .ai/profiles/ztop
  assert_no_file .ai/profiles/zbase
  assert_eq "$(cat manifest.before.tmp)" "$(cat .ai/manifest)"

  rm -rf "$src"
}

test_upgrade_refuses_a_stack_that_does_not_resolve_before_placing_a_file_link_mode() {
  skip_unless_symlinks
  fixture_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-stack-src.XXXXXX")
  _stack_source "$src"
  printf 'name: ztop\nextends: ghost\n' > "$src/profiles/ztop/profile.yaml"
  fixture_release_source "$src"
  jig init --from "$src" --link --profiles generic >/dev/null
  printf 'profiles: [generic, ztop]\nadapters: [claude, codex]\n' > .ai/config.yaml
  cp .ai/manifest manifest.before.tmp

  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "ztop: extends 'ghost'"
  assert_no_file .ai/profiles/ztop
  assert_eq "$(cat manifest.before.tmp)" "$(cat .ai/manifest)"

  rm -rf "$src"
}

test_upgrade_links_the_base_of_a_listed_layer_in_link_mode() {
  skip_unless_symlinks
  fixture_repo
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-stack-src.XXXXXX")
  _stack_source "$src"
  jig init --from "$src" --link --profiles generic >/dev/null
  printf 'profiles: [generic, ztop]\nadapters: [claude, codex]\n' > .ai/config.yaml

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_symlink .ai/profiles/ztop
  assert_symlink .ai/profiles/zbase

  rm -rf "$src"
}

test_upgrade_refuses_a_project_profile_under_a_stock_name() {
  fixture_repo
  jig init --from "$JIG_HOME" --profiles generic >/dev/null
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-stack-src.XXXXXX")
  _stack_source "$src"
  # The project wrote its own `zbase` before the release shipped one.
  mkdir -p .ai/profiles/zbase
  printf 'name: zbase\ndetect: [mine.txt]\n' > .ai/profiles/zbase/profile.yaml
  printf 'profiles: [generic, zbase]\nadapters: [claude, codex]\n' > .ai/config.yaml

  run jig upgrade --from "$src"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "profile '.ai/profiles/zbase' is the project's own, but 'zbase' is a stock profile"
  assert_file_contains .ai/profiles/zbase/profile.yaml "mine.txt"

  rm -rf "$src"
}

test_upgrade_finishes_an_interrupted_base_install_instead_of_refusing_it() {
  fixture_repo
  jig init --from "$JIG_HOME" --profiles generic >/dev/null
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-stack-src.XXXXXX")
  _stack_source "$src"
  # An upgrade that died after placing zbase: its files are here, the manifest
  # (written once, at the end) does not know them.
  cp -R "$src/profiles/zbase" .ai/profiles/zbase
  printf 'profiles: [generic, ztop]\nadapters: [claude, codex]\n' > .ai/config.yaml

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_not_contains "$OUT" "is the project's own"
  assert_file_contains .ai/manifest ".ai/profiles/zbase/profile.yaml"
  assert_file .ai/profiles/ztop/profile.yaml

  rm -rf "$src"
}

test_upgrade_a_project_layer_over_a_stock_base_installs_the_base() {
  fixture_repo
  jig init --from "$JIG_HOME" --profiles generic >/dev/null
  local src
  src=$(mktemp -d "${TMPDIR:-/tmp}/jig-stack-src.XXXXXX")
  _stack_source "$src"
  mkdir -p .ai/profiles/mine
  printf 'name: mine\nextends: zbase\n' > .ai/profiles/mine/profile.yaml
  printf 'profiles: [generic, mine]\nadapters: [claude, codex]\n' > .ai/config.yaml

  run jig upgrade --from "$src"
  assert_eq 0 "$RC"
  assert_file .ai/profiles/zbase/verify.sh
  # The project's own layer is not the manifest's to track.
  run grep -c '.ai/profiles/mine/' .ai/manifest
  assert_eq "0" "$OUT"

  rm -rf "$src"
}
