package proc

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestFakeAnswersFromTable(t *testing.T) {
	x, log := Fake(map[string]Reply{
		Key("git", "-c", "core.fsmonitor=false", "-C", "/r", "rev-parse", "--short=7", "HEAD"): {Stdout: "abc1234\n"},
		Key("git", "-c", "core.fsmonitor=false", "-C", "/r", "tag"):                            {Stderr: "boom", Code: 3},
	})
	r, err := x.Git("/r", "rev-parse", "--short=7", "HEAD")
	if err != nil || r.Stdout != "abc1234\n" || r.Code != 0 {
		t.Fatalf("got %+v, %v", r, err)
	}
	r, err = x.Git("/r", "tag")
	if err != nil || r.Code != 3 || r.Stderr != "boom" {
		t.Fatalf("got %+v, %v", r, err)
	}
	if n := len(log.Calls()); n != 2 {
		t.Errorf("calls = %d, want 2", n)
	}
	if len(log.Unexpected()) != 0 {
		t.Errorf("unexpected = %v", log.Unexpected())
	}
}

func TestFakeRefusesAnUnexpectedCall(t *testing.T) {
	x, log := Fake(nil)
	_, err := x.Git("/r", "status")
	if err == nil || !strings.Contains(err.Error(), "unexpected call") {
		t.Fatalf("err = %v", err)
	}
	if len(log.Unexpected()) != 1 {
		t.Errorf("unexpected = %v", log.Unexpected())
	}
}

func TestGitAlwaysPrependsFsmonitorOffAndDir(t *testing.T) {
	x, log := Fake(map[string]Reply{
		Key("git", "-c", "core.fsmonitor=false", "-C", "/d", "log"): {},
	})
	if _, err := x.Git("/d", "log"); err != nil {
		t.Fatal(err)
	}
	got := strings.Join(log.Calls()[0].Args, " ")
	if want := "-c core.fsmonitor=false -C /d log"; got != want {
		t.Errorf("argv = %q, want %q", got, want)
	}
}

func TestZeroExecIsAnError(t *testing.T) {
	if _, err := (Exec{}).Run(Cmd{Name: "x"}); err == nil {
		t.Error("want an error")
	}
}

func needGit(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
}

func TestRealRunsGitInATempRepository(t *testing.T) {
	needGit(t)
	dir := t.TempDir()
	x := Real()
	if r, err := x.Git(dir, "init", "-q", "."); err != nil || r.Code != 0 {
		t.Fatalf("init: %+v, %v", r, err)
	}
	r, err := x.Git(dir, "rev-parse", "--is-inside-work-tree")
	if err != nil || r.Code != 0 || strings.TrimSpace(r.Stdout) != "true" {
		t.Fatalf("rev-parse: %+v, %v", r, err)
	}
}

func TestRealReportsANonZeroExitAsACode(t *testing.T) {
	needGit(t)
	r, err := Real().Git(t.TempDir(), "rev-parse", "HEAD")
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if r.Code == 0 || r.Stderr == "" {
		t.Errorf("want a failing status and a message, got %+v", r)
	}
}

func TestRealReportsAMissingProgramAsAnError(t *testing.T) {
	if _, err := Real().Run(Cmd{Name: "jig-next-no-such-program"}); err == nil {
		t.Error("want an error")
	}
}

func TestRealPassesStdinEnvAndDir(t *testing.T) {
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skip("sh is not installed")
	}
	dir := t.TempDir()
	r, err := Real().Run(Cmd{Name: "sh", Args: []string{"-c", "cat; printf %s \"$JIG_NEXT_PROBE\"; pwd -P"}, Dir: dir, Env: []string{"JIG_NEXT_PROBE=e"}, Stdin: "in"})
	if err != nil || r.Code != 0 {
		t.Fatalf("%+v, %v", r, err)
	}
	if !strings.HasPrefix(r.Stdout, "ine") {
		t.Errorf("stdout = %q", r.Stdout)
	}
}

// A GIT_DIR (or another git location variable) in the environment points git at
// another repository than `-C`; the executor clears them, as bash does
// (jig_clear_git_location_env), so the answer is about the directory asked.
func TestRealGitIgnoresALeakedGitDir(t *testing.T) {
	needGit(t)
	x := Real()
	asked, other := t.TempDir(), t.TempDir()
	for _, d := range []string{asked, other} {
		if r, err := x.Git(d, "init", "-q", "."); err != nil || r.Code != 0 {
			t.Fatalf("init %s: %+v, %v", d, r, err)
		}
	}
	t.Setenv("GIT_DIR", other+"/.git")
	t.Setenv("GIT_WORK_TREE", other)
	r, err := x.Git(asked, "rev-parse", "--absolute-git-dir")
	if err != nil || r.Code != 0 {
		t.Fatalf("rev-parse: %+v, %v", r, err)
	}
	got, _ := os.Stat(strings.TrimSpace(r.Stdout))
	want, _ := os.Stat(asked + "/.git")
	if got == nil || want == nil || !os.SameFile(got, want) {
		t.Errorf("git answered for %q, want %s/.git", strings.TrimSpace(r.Stdout), asked)
	}
}
