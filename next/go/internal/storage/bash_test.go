package storage

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// repoRoot is the root of the Jig repository this module lives in.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "scripts", "lib", "common.sh")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("scripts/lib/common.sh not found above the package")
		}
		dir = parent
	}
}

// needBash skips the test when bash is not there: the bash implementation is
// the oracle of these tests, and without it they have nothing to ask.
func needBash(t *testing.T) string {
	t.Helper()
	path, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash is not installed")
	}
	return path
}

// baselineTag is the rollback baseline of the rewrite
// (adr-20261126-jig-1-0-is-rewritten-off-bash-and-the-pilot-picks-the-language):
// the bash implementation the storage tests ask is the one at this tag, not the
// checkout, which is an epic branch that keeps changing bash.
const baselineTag = "v0.51.2"

// baseline is the libraries of the oracle, extracted once per test process.
var baseline struct {
	once sync.Once
	dir  string
	err  error
}

// TestMain removes the extracted baseline when the package's tests are done.
func TestMain(m *testing.M) {
	code := m.Run()
	if baseline.dir != "" {
		_ = os.RemoveAll(baseline.dir)
	}
	os.Exit(code)
}

// baselineLib is the directory holding scripts/lib as at baselineTag, plus
// clock.sh: the clock section of this checkout's common.sh. The files come from
// `git cat-file`, so they are the committed bytes whatever core.autocrlf says.
func baselineLib(t *testing.T) string {
	t.Helper()
	baseline.once.Do(func() { baseline.dir, baseline.err = extractBaseline(repoRoot(t)) })
	if baseline.err != nil {
		t.Fatal(baseline.err)
	}
	return baseline.dir
}

func extractBaseline(root string) (string, error) {
	git := func(args ...string) ([]byte, error) {
		out, err := exec.Command("git", append([]string{"-C", root}, args...)...).Output()
		if err != nil {
			return nil, fmt.Errorf("the bash oracle needs the rollback baseline tag %s: run `git fetch origin tag %s` (git %s: %w)",
				baselineTag, baselineTag, strings.Join(args, " "), err)
		}
		return out, nil
	}
	listing, err := git("ls-tree", "--name-only", baselineTag, "scripts/lib/")
	if err != nil {
		return "", err
	}
	dir, err := os.MkdirTemp("", "jig-oracle-baseline-")
	if err != nil {
		return "", err
	}
	for _, path := range strings.Fields(string(listing)) {
		blob, err := git("cat-file", "blob", baselineTag+":"+path)
		if err != nil {
			_ = os.RemoveAll(dir)
			return "", err
		}
		if err := os.WriteFile(filepath.Join(dir, filepath.Base(path)), blob, 0o644); err != nil {
			_ = os.RemoveAll(dir)
			return "", err
		}
	}
	clock, err := clockSection(filepath.Join(root, "scripts", "lib", "common.sh"))
	if err != nil {
		_ = os.RemoveAll(dir)
		return "", err
	}
	if err := os.WriteFile(filepath.Join(dir, "clock.sh"), clock, 0o644); err != nil {
		_ = os.RemoveAll(dir)
		return "", err
	}
	return dir, nil
}

// clockSection is the lines of common.sh from the clock section's heading to
// jig_today, the section's last line.
func clockSection(common string) ([]byte, error) {
	data, err := os.ReadFile(common)
	if err != nil {
		return nil, err
	}
	var out []string
	in := false
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "# --- the clock ---") {
			in = true
		}
		if in {
			out = append(out, line)
			if strings.HasPrefix(line, "jig_today() {") {
				return []byte(strings.Join(out, "\n") + "\n"), nil
			}
		}
	}
	return nil, fmt.Errorf("the clock section is not in %s", common)
}

// prelude sources the libraries of the bash implementation that the readers and
// writers live in, as at the rollback baseline, from JIG_LIB.
//
// The baseline reads the clock through `date` and knows nothing of JIG_NOW; the
// checkout's clock section (clock.sh) is the clock seam, and the `date` function
// lays it over the baseline: with JIG_NOW set, a `date` that reads "now" answers
// the pinned instant. Pinning is blanket: it also pins the few reads the baseline
// makes for waits and mtimes, which these tests do not call. The pinned form of
// jig_now_date itself runs `date -d @N` / `date -r N`, which carry -d / -r and so
// go to the real `date` (no recursion).
const prelude = `
export JIG_LIB
. "$JIG_LIB/version.sh"
. "$JIG_LIB/common.sh"
. "$JIG_LIB/config.sh"
. "$JIG_LIB/frontmatter.sh"
. "$JIG_LIB/task.sh"
. "$JIG_LIB/clock.sh"
date() {
  local a
  if [ -n "${JIG_NOW:-}" ]; then
    for a in "$@"; do
      case "$a" in
        -d* | -r* | -j | -f*) command date "$@"; return ;;
      esac
    done
    jig_now_date "$@"
    return
  fi
  command date "$@"
}
`

// runBash runs script after the prelude, with the repository named in
// JIG_REPO, extra environment entries, stdin and positional arguments. It fails
// the test on a non-zero exit.
func runBash(t *testing.T, script string, env []string, stdin string, args ...string) []byte {
	t.Helper()
	bash := needBash(t)
	lib := filepath.ToSlash(baselineLib(t))
	cmd := exec.Command(bash, append([]string{"-c", prelude + script, "bash"}, args...)...)
	cmd.Env = append(os.Environ(), append([]string{"JIG_REPO=" + repoRoot(t), "JIG_LIB=" + lib}, env...)...)
	cmd.Stdin = bytes.NewReader([]byte(stdin))
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("bash: %v\n%s", err, errb.String())
	}
	return out.Bytes()
}
