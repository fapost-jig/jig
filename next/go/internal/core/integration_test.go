package core

import (
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/proc"
)

// TestContextOnARealRepository runs the stateless form on a real git checkout:
// the one place the answers of git are not faked.
func TestContextOnARealRepository(t *testing.T) {
	root := fixture(t)
	ex := proc.Real()
	git := func(args ...string) {
		t.Helper()
		r, err := ex.Run(proc.Cmd{Name: "git", Dir: root, Args: append([]string{
			"-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"}, args...)})
		if err != nil || r.Code != 0 {
			t.Skipf("git %v: %v %+v", args, err, r)
		}
	}
	git("init", "-q", "-b", "main")
	write(t, root, ".gitignore", ".ai/runtime/\n")
	write(t, root, "base.go", "package a\n")
	knowledgeDoc(t, root, "f.md", "feature-f", "active", "paths: [\"*.go\"]\n")
	git("add", "-A")
	git("commit", "-q", "-m", "base")
	git("checkout", "-q", "-b", "feat")
	write(t, root, "changed.go", "package a\n")
	write(t, root, "base.go", "package b\n")
	git("add", "base.go")

	out := Context(Ctx{Exec: ex, Clock: mustClock(""), Env: func(string) string { return "" }, Cwd: root}, []string{"--format", "paths"})
	if got, want := text(out), ".ai/knowledge/f.md\n"; got != want {
		t.Errorf("%q, want %q", got, want)
	}
	if out.Code != 0 || strings.Contains(text(out), "err") {
		t.Errorf("%d %q", out.Code, text(out))
	}
}
