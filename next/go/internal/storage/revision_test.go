package storage

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/clock"
)

const bashRevisionRead = `jig_revision_read`
const bashRevisionDir = `jig_revision_dir`
const bashRevisionBump = `n=$1; while [ "$n" -gt 0 ]; do jig_revision_bump; n=$((n - 1)); done`

func pinnedClock(t *testing.T) clock.Clock {
	t.Helper()
	clk, err := clock.New(pinnedNow)
	if err != nil {
		t.Fatal(err)
	}
	return clk
}

func names(t *testing.T, dir string) string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	sort.Strings(out)
	return strings.Join(out, " ")
}

func TestAFirstRaiseClaimsTheTimeAndBashReadsIt(t *testing.T) {
	root := t.TempDir()
	if got := RevisionRead(root); got != 0 {
		t.Fatalf("revision before any write: %d", got)
	}
	if err := RevisionBump(root, pinnedClock(t)); err != nil {
		t.Fatal(err)
	}
	if got := RevisionRead(root); strconv.FormatUint(got, 10) != pinnedNow {
		t.Fatalf("first raise claimed %d, want %s", got, pinnedNow)
	}
	env := []string{"JIG_NOW=" + pinnedNow, "JIG_PROJECT=" + root}
	if got := strings.TrimSpace(string(runBash(t, bashRevisionRead, env, ""))); got != pinnedNow {
		t.Fatalf("bash reads %q, want %s", got, pinnedNow)
	}
}

func TestGoAndBashRaiseOneCounter(t *testing.T) {
	root := t.TempDir()
	env := []string{"JIG_NOW=" + pinnedNow, "JIG_PROJECT=" + root}
	runBash(t, bashRevisionBump, env, "", "3")
	before := RevisionRead(root)
	if err := RevisionBump(root, pinnedClock(t)); err != nil {
		t.Fatal(err)
	}
	runBash(t, bashRevisionBump, env, "", "1")
	got := strings.TrimSpace(string(runBash(t, bashRevisionRead, env, "")))
	if want := strconv.FormatUint(before+2, 10); got != want {
		t.Fatalf("after bash, Go, bash: %s, want %s", got, want)
	}
}

func TestRaisesClearOldNamesAsBashDoes(t *testing.T) {
	goRoot, bashRoot := t.TempDir(), t.TempDir()
	clk := pinnedClock(t)
	for i := 0; i < 40; i++ {
		if err := RevisionBump(goRoot, clk); err != nil {
			t.Fatal(err)
		}
	}
	runBash(t, bashRevisionBump, []string{"JIG_NOW=" + pinnedNow, "JIG_PROJECT=" + bashRoot}, "", "40")
	got, want := names(t, RevisionDir(goRoot)), names(t, RevisionDir(bashRoot))
	if got != want {
		t.Fatalf("names after 40 raises:\n go:   %s\n bash: %s", got, want)
	}
}

func TestAStateWriteRaisesTheRevision(t *testing.T) {
	root := projectWithState(t, "t1", "task_id: t1\nstatus: draft\n")
	clk := pinnedClock(t)
	before := RevisionRead(root)
	if err := TaskStateSet(root, "t1", "status", "ready", clk); err != nil {
		t.Fatal(err)
	}
	afterSet := RevisionRead(root)
	if afterSet == before {
		t.Fatal("TaskStateSet left the revision where it was")
	}
	if err := TaskStateRemove(root, "t1", []string{"status"}, clk); err != nil {
		t.Fatal(err)
	}
	if RevisionRead(root) != afterSet+1 {
		t.Fatalf("TaskStateRemove: revision %d, want %d", RevisionRead(root), afterSet+1)
	}
}

// A linked worktree and its main checkout raise one counter: the main
// checkout's. Bash, which reads git's own files the same way, is the oracle of
// where that is.
func TestAWorktreeFindsTheCounterBashFinds(t *testing.T) {
	base := t.TempDir()
	main := filepath.Join(base, "main")
	wt := filepath.Join(base, "wt")
	runBash(t, `set -e
git init -q "$1"
git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$1" worktree add -q "$2" -b wt`, nil, "", main, wt)
	realMain, err := filepath.EvalSymlinks(main)
	if err != nil {
		t.Fatal(err)
	}
	for _, root := range []string{main, wt} {
		got := RevisionDir(root)
		bashDir := strings.TrimSpace(string(runBash(t, bashRevisionDir, []string{"JIG_PROJECT=" + root}, "")))
		if got != bashDir {
			t.Errorf("%s: go %s, bash %s", root, got, bashDir)
		}
		if root == wt && got != filepath.Join(realMain, ".ai", "runtime", "revision") {
			t.Errorf("the worktree's counter is %s, not the main checkout's", got)
		}
	}
}

// A clone whose git directory is not named .git keeps the counter under it,
// where bash keeps it (jig_config_odd_common).
func TestASeparateGitDirKeepsTheCounterWhereBashDoes(t *testing.T) {
	base := t.TempDir()
	work := filepath.Join(base, "work")
	runBash(t, `set -e; git init -q --separate-git-dir "$2" "$1"`, nil, "", work, filepath.Join(base, "repo.git"))
	got := RevisionDir(work)
	bashDir := strings.TrimSpace(string(runBash(t, bashRevisionDir, []string{"JIG_PROJECT=" + work}, "")))
	if got != bashDir {
		t.Fatalf("go %s, bash %s", got, bashDir)
	}
	if filepath.Base(filepath.Dir(got)) != "jig" {
		t.Fatalf("the counter is %s, not under the git directory", got)
	}
}

// A stale claim that cannot be withdrawn does not end the raise: bash ignores
// the failed rm and reads again, and so does Go.
func TestAStaleClaimThatCannotBeWithdrawnIsReadAgain(t *testing.T) {
	root := t.TempDir()
	dir := RevisionDir(root)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "100"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	far := uint64(100 + 1 + revisionKeep + 5)
	claims, removals := 0, 0
	claim, remove := claimRevisionFile, removeRevisionFile
	t.Cleanup(func() { claimRevisionFile, removeRevisionFile = claim, remove })
	claimRevisionFile = func(path string) bool {
		claims++
		ok := claim(path)
		if claims == 1 {
			// Another writer got far ahead while this one stalled.
			if err := os.WriteFile(filepath.Join(dir, strconv.FormatUint(far, 10)), nil, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		return ok
	}
	removeRevisionFile = func(path string) error {
		removals++
		if removals == 1 {
			return fs.ErrPermission
		}
		return remove(path)
	}
	if err := RevisionBump(root, pinnedClock(t)); err != nil {
		t.Fatalf("RevisionBump: %v", err)
	}
	if removals != 1 || claims != 2 {
		t.Fatalf("claims=%d removals=%d, want 2 and 1", claims, removals)
	}
	if got := RevisionRead(root); got != far+1 {
		t.Fatalf("revision %d, want %d", got, far+1)
	}
}
