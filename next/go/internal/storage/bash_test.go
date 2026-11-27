package storage

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
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

// prelude sources the libraries of the bash implementation that the readers and
// writers live in.
const prelude = `
JIG_LIB="$JIG_REPO/scripts/lib"; export JIG_LIB
. "$JIG_LIB/version.sh"
. "$JIG_LIB/common.sh"
. "$JIG_LIB/config.sh"
. "$JIG_LIB/frontmatter.sh"
. "$JIG_LIB/task.sh"
`

// runBash runs script after the prelude, with the repository named in
// JIG_REPO, extra environment entries, stdin and positional arguments. It fails
// the test on a non-zero exit.
func runBash(t *testing.T, script string, env []string, stdin string, args ...string) []byte {
	t.Helper()
	bash := needBash(t)
	cmd := exec.Command(bash, append([]string{"-c", prelude + script, "bash"}, args...)...)
	cmd.Env = append(os.Environ(), append([]string{"JIG_REPO=" + repoRoot(t)}, env...)...)
	cmd.Stdin = bytes.NewReader([]byte(stdin))
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("bash: %v\n%s", err, errb.String())
	}
	return out.Bytes()
}
