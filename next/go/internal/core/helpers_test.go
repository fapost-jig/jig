package core

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/clock"
	"github.com/fapost-jig/jig/next/go/internal/proc"
)

// gitKey is the key of a faked git call in dir.
func gitKey(dir string, args ...string) string {
	return proc.Key("git", append([]string{"-c", "core.fsmonitor=false", "-C", dir}, args...)...)
}

// fixture makes an initialised project in a temporary directory and returns its
// physical root.
func fixture(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	write(t, root, ".ai/config.yaml", "")
	return root
}

// write writes a file under root, with its directories.
func write(t *testing.T, root, rel, text string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// read is a file under root, "" when it is not there.
func read(root, rel string) string {
	data, _ := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	return string(data)
}

// task files a task workspace with the given state lines.
func task(t *testing.T, root, id string, state ...string) {
	t.Helper()
	write(t, root, ".ai/workspace/tasks/"+id+"/state", strings.Join(state, "\n")+"\n")
}

// ctxFor builds a Ctx for the fixture whose git answers from table; the top of
// the working tree is root, HEAD is on branch.
func ctxFor(root, branch string, env map[string]string, table map[string]proc.Reply) (Ctx, *proc.Log) {
	t := map[string]proc.Reply{
		gitKey(root, "rev-parse", "--show-toplevel"):               {Stdout: root + "\n"},
		gitKey(root, "symbolic-ref", "--short", "HEAD"):            {Stdout: branch + "\n"},
		gitKey(root, "symbolic-ref", "--quiet", "--short", "HEAD"): {Stdout: branch + "\n"},
	}
	for k, v := range table {
		t[k] = v
	}
	// The top of the tree is asked from the working directory the Ctx names.
	t[gitKey(root, "rev-parse", "--show-toplevel")] = proc.Reply{Stdout: root + "\n"}
	x, log := proc.Fake(t)
	return Ctx{
		Root:  "",
		Exec:  x,
		Clock: mustClock("1700000000"),
		Env:   func(k string) string { return env[k] },
		Cwd:   root,
	}, log
}

func mustClock(v string) clock.Clock {
	c, err := clock.New(v)
	if err != nil {
		panic(err)
	}
	return c
}

// text is everything an Output printed, stdout and stderr in order, stderr
// lines marked.
func text(o Output) string {
	var b bytes.Buffer
	for _, c := range o.Chunks {
		if c.Stderr {
			b.WriteString("[err] ")
		}
		b.WriteString(c.Text)
	}
	return b.String()
}
