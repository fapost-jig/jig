package storage

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/clock"
)

// The clone's revision (adr-20261016-the-clone-revision-is-a-claimed-name): one
// counter per clone, raised by every Jig write and reported by every --json
// read. Its value is the highest numeric name in the revision directory;
// raising it claims the next name by an exclusive create, so of two writers
// that saw <n> exactly one makes <n+1>. The rules are bash 0.51.2's
// (scripts/lib/common.sh: jig_revision_dir, _jig_revision_scan,
// jig_revision_bump, _jig_revision_clear), so both implementations raise and
// read one counter.

// revisionKeep is how far below a claim a name must be before a raise clears
// it (_JIG_REV_KEEP).
const revisionKeep = 16

// RevisionDir is where the counter of the clone that project root belongs to
// lives (jig_revision_dir): under the git common directory when that is not
// named .git, else under the main checkout's .ai/runtime/revision.
func RevisionDir(root string) string {
	if common, ok := oddCommon(root); ok {
		return filepath.Join(common, "jig", "revision")
	}
	return filepath.Join(cloneRoot(root), ".ai", "runtime", "revision")
}

// gitdirOf is the git directory a worktree's .git file names, resolved against
// root, or false when root/.git is not such a file (jig_config_odd_common and
// _jig_config_clone_root_find read git's own files, not git).
func gitdirOf(root string) (string, bool) {
	data, err := os.ReadFile(filepath.Join(root, ".git"))
	if err != nil {
		return "", false
	}
	line, _, _ := strings.Cut(string(data), "\n")
	gitdir, found := strings.CutPrefix(line, "gitdir: ")
	if !found || gitdir == "" {
		return "", false
	}
	if !filepath.IsAbs(gitdir) {
		gitdir = filepath.Join(root, gitdir)
	}
	if info, err := os.Stat(gitdir); err != nil || !info.IsDir() {
		return "", false
	}
	return gitdir, true
}

// commondirOf is the directory gitdir's commondir file names, resolved against
// gitdir and through symlinks (`cd` then `pwd -P`).
func commondirOf(gitdir string) (string, bool) {
	data, err := os.ReadFile(filepath.Join(gitdir, "commondir"))
	if err != nil {
		return "", false
	}
	common, _, _ := strings.Cut(string(data), "\n")
	if common == "" {
		return "", false
	}
	if !filepath.IsAbs(common) {
		common = filepath.Join(gitdir, common)
	}
	real, err := filepath.EvalSymlinks(common)
	if err != nil {
		return "", false
	}
	return real, true
}

// cloneRoot is the main checkout of the clone root belongs to
// (_jig_config_clone_root_find): a linked worktree answers the checkout it was
// added from; anything else answers root itself.
func cloneRoot(root string) string {
	gitdir, ok := gitdirOf(root)
	if !ok {
		return root
	}
	common, ok := commondirOf(gitdir)
	if !ok || filepath.Base(common) != ".git" {
		return root
	}
	return filepath.Dir(common)
}

// oddCommon is the clone's git common directory when it is not named .git
// (jig_config_odd_common): a separate git dir, a submodule, a bare repository
// with linked worktrees.
func oddCommon(root string) (string, bool) {
	gitdir, ok := gitdirOf(root)
	if !ok {
		return "", false
	}
	here := gitdir
	if _, err := os.Stat(filepath.Join(gitdir, "commondir")); err == nil {
		common, ok := commondirOf(gitdir)
		if !ok {
			return "", false
		}
		here = common
	} else if real, err := filepath.EvalSymlinks(gitdir); err == nil {
		here = real
	} else {
		return "", false
	}
	if filepath.Base(here) == ".git" {
		return "", false
	}
	return here, true
}

// scanRevision is _jig_revision_scan: the highest numeric name in dir (found
// false when there is none) and the other numeric names. A name is a file (a
// claim) or a directory (the counter of the first, rename-based version).
func scanRevision(dir string) (highest uint64, found bool, others []string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, false, nil
	}
	var highName string
	for _, e := range entries {
		name := e.Name()
		n, ok := revisionNumber(name)
		if !ok {
			continue
		}
		switch {
		case !found:
			highest, highName, found = n, name, true
		case n > highest:
			others = append(others, highName)
			highest, highName = n, name
		default:
			others = append(others, name)
		}
	}
	return highest, found, others
}

// revisionNumber reads a name of digits only; anything else is not a name of
// the counter.
func revisionNumber(name string) (uint64, bool) {
	if name == "" {
		return 0, false
	}
	for i := 0; i < len(name); i++ {
		if name[i] < '0' || name[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseUint(name, 10, 64)
	return n, err == nil
}

// RevisionRead is the clone's revision, 0 when Jig has written nothing in it
// yet (jig_revision_read).
func RevisionRead(root string) uint64 {
	n, _, _ := scanRevision(RevisionDir(root))
	return n
}

// claimFile creates path, empty, only if nothing is there (jig_claim_file):
// true when this process created it.
func claimFile(path string) bool {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return false
	}
	_ = f.Close()
	return true
}

// clearRevision removes the names in names below below, at most 16, best
// effort (_jig_revision_clear). Each is a digits-only name inside dir.
func clearRevision(dir string, below uint64, names []string) {
	count := 0
	for _, name := range names {
		n, ok := revisionNumber(name)
		if !ok || n >= below {
			continue
		}
		if count >= 16 {
			break
		}
		count++
		_ = os.Remove(filepath.Join(dir, name))
	}
}

// ErrRevisionNotRaised says a write landed but the counter could not be
// raised. The write is not undone: a caller warns, as jig_revision_bump does,
// and does not fail.
var ErrRevisionNotRaised = errors.New("could not raise the clone revision")

// RevisionBump raises the clone's revision by one after a write landed
// (jig_revision_bump). A first write claims the current time in seconds rather
// than 1, so a revision a consumer still holds from before a lost .ai/runtime
// does not come round again. A claim that loses reads again; a claim that
// finds the highest name more than revisionKeep above it was made stale by a
// stall, and is withdrawn and made again.
func RevisionBump(root string, clk clock.Clock) error {
	dir := RevisionDir(root)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("%w: cannot create %s", ErrRevisionNotRaised, dir)
	}
	for tries := 0; tries < 64; tries++ {
		seen, found, others := scanRevision(dir)
		var next uint64
		if !found {
			next = uint64(clk.Now().Unix())
		} else {
			next = seen + 1
			others = append(others, strconv.FormatUint(seen, 10))
		}
		name := filepath.Join(dir, strconv.FormatUint(next, 10))
		if !claimFile(name) {
			continue
		}
		high, _, _ := scanRevision(dir)
		if high <= next+revisionKeep {
			if next > revisionKeep {
				clearRevision(dir, next-revisionKeep, others)
			}
			return nil
		}
		if err := os.Remove(name); err != nil && !errors.Is(err, fs.ErrNotExist) {
			break
		}
	}
	return fmt.Errorf("%w in %s; a reader may miss this change", ErrRevisionNotRaised, dir)
}
