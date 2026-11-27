package core

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/proc"
)

// frameworkRoot makes a directory that looks like a framework source with the
// claude and codex adapters.
func frameworkRoot(t *testing.T) string {
	t.Helper()
	fw := fixture(t)
	for _, f := range []string{"skills/x", "templates/x", "scripts/jig", "adapters/claude/adapter.sh", "adapters/codex/adapter.sh"} {
		write(t, fw, f, "")
	}
	return fw
}

func recordCtx(t *testing.T, root, branch, fw string, env map[string]string, table map[string]proc.Reply) Ctx {
	t.Helper()
	ctx, _ := ctxFor(root, branch, env, table)
	ctx.Root = fw
	return ctx
}

func TestCheckoutRecordWritesTheCheckoutAndTheSessionsWorkingRecord(t *testing.T) {
	root, fw := fixture(t), frameworkRoot(t)
	write(t, root, ".ai/runtime/checkout", "command: old\nbranch_reported: feat\n")
	ctx := recordCtx(t, root, "main", fw, map[string]string{"CLAUDE_CODE_SESSION_ID": "sess-1"}, nil)
	CheckoutRecord(ctx, []string{"context", "--files", "a,b"})
	if got, want := read(root, ".ai/runtime/checkout"), "command: context --files a,b\nbranch_reported: feat\n"; got != want {
		t.Errorf("checkout record %q", got)
	}
	if got, want := read(root, ".ai/runtime/working/sess-1"), "command: context --files a,b\n"; got != want {
		t.Errorf("working record %q", got)
	}
}

func TestCheckoutRecordNeedsAnAdapterForTheSession(t *testing.T) {
	root := fixture(t)
	for name, tc := range map[string]struct {
		fw  string
		env map[string]string
	}{
		"no framework": {"", map[string]string{"CLAUDE_CODE_SESSION_ID": "s"}},
		"no variable":  {frameworkRoot(t), nil},
		"bad id":       {frameworkRoot(t), map[string]string{"CLAUDE_CODE_SESSION_ID": "a/b"}},
	} {
		ctx := recordCtx(t, root, "main", tc.fw, tc.env, nil)
		CheckoutRecord(ctx, []string{"context"})
		if _, err := os.Stat(filepath.Join(root, ".ai/runtime/working")); err == nil {
			t.Errorf("%s: a working record was written", name)
		}
	}
	// codex only: it names no session.
	fw := frameworkRoot(t)
	write(t, root, ".ai/config.yaml", "adapters: [codex]\n")
	ctx := recordCtx(t, root, "main", fw, map[string]string{"CLAUDE_CODE_SESSION_ID": "s"}, nil)
	CheckoutRecord(ctx, []string{"context"})
	if _, err := os.Stat(filepath.Join(root, ".ai/runtime/working")); err == nil {
		t.Error("codex gave a session")
	}
}

func TestCheckoutRecordNamesTheWorkAfterATaskInTheArguments(t *testing.T) {
	root, fw := fixture(t), frameworkRoot(t)
	task(t, root, "T-1", "status: active", "branch: feat")
	task(t, root, "T-2", "status: active", "branch: other")
	list := "worktree /x\nbranch refs/heads/main\n\nworktree /y\nbranch refs/heads/other\n"
	table := map[string]proc.Reply{gitKey(root, "worktree", "list", "--porcelain"): {Stdout: list}}
	ctx := recordCtx(t, root, "main", fw, map[string]string{"CLAUDE_CODE_SESSION_ID": "sess-1"}, table)

	// T-2 lives in another worktree: it is not work here; HEAD names no task, so the session names it.
	CheckoutRecord(ctx, []string{"context", "--task", "T-2"})
	if _, err := os.Stat(filepath.Join(root, ".ai/runtime/working/T-2")); err == nil {
		t.Error("a task checked out elsewhere was recorded as work here")
	}
	if read(root, ".ai/runtime/working/sess-1") == "" {
		t.Error("the session's record is missing")
	}
	// T-1 is named: the record is the task's, and says which session wrote it.
	CheckoutRecord(ctx, []string{"context", "--task", "T-1"})
	if got, want := read(root, ".ai/runtime/working/T-1"), "command: context --task T-1\nsession: sess-1\n"; got != want {
		t.Errorf("%q", got)
	}
}

func TestCheckoutRecordNamesTheWorkAfterTheTaskOnHead(t *testing.T) {
	root, fw := fixture(t), frameworkRoot(t)
	task(t, root, "on-head", "status: ready", "branch: feat")
	task(t, root, "done", "status: consolidated", "branch: feat")
	ctx := recordCtx(t, root, "feat", fw, nil, nil)
	CheckoutRecord(ctx, []string{"context", "--files", "a\nb"})
	if got, want := read(root, ".ai/runtime/working/on-head"), "command: context --files a b\n"; got != want {
		t.Errorf("%q", got)
	}
	// The checkout record keeps the line break an argument holds.
	if got := read(root, ".ai/runtime/checkout"); got != "command: context --files a\nb\n" {
		t.Errorf("%q", got)
	}
}

func TestCheckoutTakeRecordsTheSessionsTaskAndRaisesTheRevision(t *testing.T) {
	root, fw := fixture(t), frameworkRoot(t)
	task(t, root, "T-1", "status: active", "branch: feat")
	ctx := recordCtx(t, root, "feat", fw, map[string]string{"CLAUDE_CODE_SESSION_ID": "sess-1"}, nil)
	CheckoutRecord(ctx, []string{"context", "--task", "T-1"})
	want := "checkout: " + root + "\nsince: 2023-11-14T22:13:20Z\ncommand: context --task T-1\n"
	if got := read(root, ".ai/runtime/taken/T-1/sess-1"); got != want {
		t.Errorf("taken %q", got)
	}
	revs, _ := os.ReadDir(filepath.Join(root, ".ai/runtime/revision"))
	if len(revs) != 1 || revs[0].Name() != "1700000000" {
		t.Errorf("revision %v", revs)
	}
	// A command that works no task takes none: `context` without a task id.
	CheckoutRecord(ctx, []string{"context", "--files", "x"})
	if got := read(root, ".ai/runtime/taken/T-1/sess-1"); got != want {
		t.Errorf("a command with no task rewrote the taken record: %q", got)
	}
}

func TestCheckoutReviveTakesTheEndedMarkOff(t *testing.T) {
	root, fw := fixture(t), frameworkRoot(t)
	write(t, root, ".ai/runtime/taken/T-1/sess-1", "checkout: /c\r\nsince: s\nended: 2026\n")
	ctx := recordCtx(t, root, "main", fw, map[string]string{"CLAUDE_CODE_SESSION_ID": "sess-1"}, nil)
	CheckoutRecord(ctx, []string{"context"})
	if got, want := read(root, ".ai/runtime/taken/T-1/sess-1"), "checkout: /c\nsince: s\n"; got != want {
		t.Errorf("%q", got)
	}
}

func TestCheckoutRecordIsSkippedForARedrawAndOutsideAProject(t *testing.T) {
	root, fw := fixture(t), frameworkRoot(t)
	ctx := recordCtx(t, root, "main", fw, map[string]string{"JIG_INTERNAL_REDRAW": "1"}, nil)
	CheckoutRecord(ctx, []string{"context"})
	if _, err := os.Stat(filepath.Join(root, ".ai/runtime")); err == nil {
		t.Error("a redraw left a record")
	}
	x, _ := proc.Fake(map[string]proc.Reply{gitKey(root, "rev-parse", "--show-toplevel"): {Code: 128}})
	ctx = recordCtx(t, root, "main", fw, nil, nil)
	ctx.Exec = x
	CheckoutRecord(ctx, []string{"context"})
	if _, err := os.Stat(filepath.Join(root, ".ai/runtime")); err == nil {
		t.Error("a record was written outside a repository")
	}
}

func TestCheckoutTTL(t *testing.T) {
	root := fixture(t)
	p := Project{Root: root}
	for value, want := range map[string]int64{"": 43200, "2h": 7200, "30m": 1800, "90s": 90, "2d": 172800, "3": 259200, "x": 43200, "h": 43200} {
		write(t, root, ".ai/config.yaml", "checkout.busy_ttl: "+value+"\n")
		if got := checkoutTTL(p); got != want {
			t.Errorf("%q: %d, want %d", value, got, want)
		}
	}
}
