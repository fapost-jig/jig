package core

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/clock"
	"github.com/fapost-jig/jig/next/go/internal/errs"
	"github.com/fapost-jig/jig/next/go/internal/proc"
)

// sourceRoot makes a minimal framework source checkout declaring version.
func sourceRoot(t *testing.T, version string) string {
	t.Helper()
	root := t.TempDir()
	for _, d := range []string{"skills", "templates", "scripts/lib"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write := func(rel, text string) {
		if err := os.WriteFile(filepath.Join(root, rel), []byte(text), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write("scripts/jig", "#!/bin/sh\n")
	write("scripts/lib/version.sh", "# comment\nJIG_VERSION=\""+version+"\"\nexport JIG_VERSION\n")
	return root
}

func fake(t *testing.T, root string, table map[string]proc.Reply) (Ctx, *proc.Log) {
	t.Helper()
	x, log := proc.Fake(table)
	return Ctx{Root: root, Exec: x, Clock: clock.Real(), Env: func(string) string { return "" }}, log
}

func gk(root string, args ...string) string {
	return proc.Key("git", append([]string{"-c", "core.fsmonitor=false", "-C", root}, args...)...)
}

func TestVersionAtItsReleaseTag(t *testing.T) {
	root := sourceRoot(t, "1.2.3")
	phys, _ := filepath.EvalSymlinks(root)
	ctx, log := fake(t, root, map[string]proc.Reply{
		gk(root, "rev-parse", "--show-toplevel"): {Stdout: phys + "\n"},
		gk(root, "tag", "--points-at", "HEAD"):   {Stdout: "v1.2.2\nv1.2.3\n"},
	})
	v, err := Version(ctx)
	if err != nil || v != "1.2.3" {
		t.Fatalf("got %q, %v", v, err)
	}
	if len(log.Unexpected()) != 0 {
		t.Errorf("unexpected calls: %v", log.Unexpected())
	}
}

func TestVersionPastItsTagTakesTheShortSha(t *testing.T) {
	root := sourceRoot(t, "1.2.3")
	phys, _ := filepath.EvalSymlinks(root)
	ctx, _ := fake(t, root, map[string]proc.Reply{
		gk(root, "rev-parse", "--show-toplevel"):   {Stdout: phys + "\n"},
		gk(root, "tag", "--points-at", "HEAD"):     {Stdout: "v1.2.2\n"},
		gk(root, "rev-parse", "--short=7", "HEAD"): {Stdout: "abc1234\n"},
	})
	v, err := Version(ctx)
	if err != nil || v != "1.2.3+abc1234" {
		t.Fatalf("got %q, %v", v, err)
	}
}

func TestVersionInsideSomebodyElsesRepositoryIsUnknown(t *testing.T) {
	root := sourceRoot(t, "1.2.3")
	ctx, _ := fake(t, root, map[string]proc.Reply{
		gk(root, "rev-parse", "--show-toplevel"): {Stdout: filepath.Dir(root) + "\n"},
	})
	v, err := Version(ctx)
	if err != nil || v != "1.2.3+unknown" {
		t.Fatalf("got %q, %v", v, err)
	}
}

func TestVersionWithoutGitIsUnknown(t *testing.T) {
	root := sourceRoot(t, "1.2.3")
	ctx, _ := fake(t, root, nil) // every git call is an error: git is not there
	v, err := Version(ctx)
	if err != nil || v != "1.2.3+unknown" {
		t.Fatalf("got %q, %v", v, err)
	}
}

func TestVersionNeverTakesAMalformedDeclaredVersionForARelease(t *testing.T) {
	root := sourceRoot(t, "1.2")
	phys, _ := filepath.EvalSymlinks(root)
	ctx, _ := fake(t, root, map[string]proc.Reply{
		gk(root, "rev-parse", "--show-toplevel"):   {Stdout: phys + "\n"},
		gk(root, "rev-parse", "--short=7", "HEAD"): {Stdout: "abc1234\n"},
	})
	v, err := Version(ctx)
	if err != nil || v != "1.2+abc1234" {
		t.Fatalf("got %q, %v", v, err)
	}
}

func TestVersionRefusals(t *testing.T) {
	for name, ctx := range map[string]Ctx{
		"no root":        {},
		"not a checkout": {Root: t.TempDir()},
	} {
		_, err := Version(ctx)
		e, ok := err.(*errs.Error)
		if !ok || e.Code != errs.Failed {
			t.Errorf("%s: err = %#v", name, err)
		}
	}
	root := t.TempDir()
	for _, d := range []string{"skills", "templates", "scripts/lib"} {
		_ = os.MkdirAll(filepath.Join(root, d), 0o755)
	}
	_ = os.WriteFile(filepath.Join(root, "scripts", "jig"), nil, 0o755)
	if _, err := Version(Ctx{Root: root}); err == nil || !strings.Contains(err.Error(), "version.sh") {
		t.Errorf("no declared version: err = %v", err)
	}
}

func TestVersionOfARealCheckoutWithRealGit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	root := sourceRoot(t, "4.5.6")
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", root,
			"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q", ".")
	run("add", "-A")
	run("commit", "-q", "-m", "release")
	ctx := Ctx{Root: root, Exec: proc.Real(), Clock: clock.Real(), Env: func(string) string { return "" }}

	v, err := Version(ctx)
	if err != nil || !strings.HasPrefix(v, "4.5.6+") || len(v) != len("4.5.6+")+7 {
		t.Fatalf("untagged: %q, %v", v, err)
	}
	run("tag", "-a", "v4.5.6", "-m", "v4.5.6")
	if v, err = Version(ctx); err != nil || v != "4.5.6" {
		t.Fatalf("tagged: %q, %v", v, err)
	}
}
