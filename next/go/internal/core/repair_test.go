package core

import (
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/fapost-jig/jig/next/go/internal/clock"
	"github.com/fapost-jig/jig/next/go/internal/proc"
)

func TestRelPathHoldsForAWindowsFormRoot(t *testing.T) {
	// Storage hands core paths with `/`, whatever the operating system.
	p := Project{Root: "C:/Users/x/proj"}
	if got := relPath(p, "C:/Users/x/proj/.ai/knowledge/a.md"); got != ".ai/knowledge/a.md" {
		t.Errorf("%q", got)
	}
}

func TestPauseOfAnAutopilotTaskWritesTheJournalLine(t *testing.T) {
	root := progressiveFixture(t)
	task(t, root, "t1", "status: active", "branch: feat", "autopilot: on")
	write(t, root, ".ai/runtime/queue", "# jig queue 1\nrequest\ttask:t1\tpause\t2023-11-14T22:13:20Z\tlunch\n")
	ctx, _ := ctxFor(root, "feat", nil, nil)
	out := Context(ctx, []string{"resolve", "--task", "t1", "--stage", "plan", "--files", "x"})
	if out.Code != 4 {
		t.Fatalf("%d %q", out.Code, text(out))
	}
	want := "2023-11-14T22:13:20Z\tpause\tplan not entered: pause requested at 2023-11-14T22:13:20Z: lunch\n"
	if got := read(root, ".ai/workspace/tasks/t1/autopilot"); got != want {
		t.Errorf("journal %q, want %q", got, want)
	}
}

func TestSha256HashingGoesThroughTheOneExecutor(t *testing.T) {
	root := progressiveFixture(t)
	table := map[string]proc.Reply{
		gitKey(root, "rev-parse", "--show-object-format"):                                       {Stdout: "sha256\n"},
		gitKey(root, "rev-parse", "--absolute-git-dir"):                                         {Stdout: root + "/.git\n"},
		gitKey(root, "--git-dir="+root+"/.git", "hash-object", "--no-filters", "--stdin-paths"): {Stdout: "aa\nbb\ncc\n"},
	}
	ctx, log := ctxFor(root, "feat", nil, table)
	h := newHasher(ctx, Project{Root: root})
	got, err := h.list(root, []string{"a", "b", "c"})
	if err != nil || strings.Join(got, ",") != "aa,bb,cc" {
		t.Errorf("%v %v", got, err)
	}
	if u := log.Unexpected(); len(u) != 0 {
		t.Errorf("a process outside the executor's form: %v", u)
	}
}

func TestTakenRecordAgeIsMeasuredOnTheFileClock(t *testing.T) {
	root, fw := fixture(t), frameworkRoot(t)
	task(t, root, "T-1", "status: active", "branch: feat")
	env := map[string]string{"CLAUDE_CODE_SESSION_ID": "sess-1"}
	file := ".ai/runtime/taken/T-1/sess-1"
	write(t, root, file, "checkout: /c\nsince: OLD\ncommand: x\n")

	live := recordCtx(t, root, "feat", fw, env, nil)
	live.FileClock = pinnedAt(t, time.Now().Unix()+60)
	CheckoutRecord(live, []string{"context", "--task", "T-1"})
	if !strings.Contains(read(root, file), "since: OLD\n") {
		t.Errorf("a live record lost its since: %q", read(root, file))
	}
	lapsed := recordCtx(t, root, "feat", fw, env, nil)
	lapsed.FileClock = pinnedAt(t, time.Now().Unix()+100000)
	CheckoutRecord(lapsed, []string{"context", "--task", "T-1"})
	if strings.Contains(read(root, file), "since: OLD") {
		t.Errorf("a lapsed record kept its since: %q", read(root, file))
	}
}

func pinnedAt(t *testing.T, secs int64) clock.Clock {
	t.Helper()
	c, err := clock.New(strconv.FormatInt(secs, 10))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestAnInvalidTaskIDBuildsNoPath(t *testing.T) {
	if _, err := taskDirOf("/r", "../x"); err == nil || err.Error() != "invalid task id: ../x" {
		t.Errorf("%v", err)
	}
	if _, err := workspaceRel("a/b"); err == nil {
		t.Error("a workspace path was built for an invalid id")
	}
	root := progressiveFixture(t)
	if _, ok := readLedger(Project{Root: root}, ".."); ok {
		t.Error("a ledger was read for an invalid id")
	}
	if rows, ok := cacheRead(newHasher(Ctx{}, Project{Root: root}), Project{Root: root}, &ctxSel{task: "x/y"}); ok || rows != nil {
		t.Error("a cache was read for an invalid id")
	}
}

func TestADriveLetterPathIsAbsoluteEverywhereItIsDecided(t *testing.T) {
	root := progressiveFixture(t)
	p := Project{Root: root}
	linked := []string{"C:/work/other/.ai/workspace/tasks/x1/task.md"}
	if got := normalisePath(p, linked[0], linked); got != linked[0] {
		t.Errorf("a linked document was rewritten: %q", got)
	}
	if got := normalisePath(p, `C:\elsewhere\a.md`, linked); got != `C:\elsewhere\a.md` {
		t.Errorf("%q", got)
	}
	if pr := checkKnowledgePath(p, linked[0], linked); pr != "" {
		t.Errorf("a linked drive path was refused: %s", pr)
	}
	if pr := checkKnowledgePath(p, "D:/other.md", linked); !strings.HasPrefix(pr, "path must be repository-relative: D:/other.md") {
		t.Errorf("%q", pr)
	}
	if pr := checkRevokedPath("D:/other.md", map[string]bool{}); !strings.HasPrefix(pr, "path must be repository-relative") {
		t.Errorf("%q", pr)
	}
	// hashPaths takes it for an absolute path: it asks its own directory, never the project's.
	ctx, _ := ctxFor(root, "feat", nil, nil)
	_, err := newHasher(ctx, p).hashPaths([]string{"C:/work/other/a.md"})
	if err == nil || !strings.Contains(err.Error(), "C:/work/other/a.md") || strings.Contains(err.Error(), root) {
		t.Errorf("hashed as a relative path: %v", err)
	}
}
