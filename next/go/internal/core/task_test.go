package core

import (
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/proc"
)

func TestTaskCandidatesRules(t *testing.T) {
	root := fixture(t)
	task(t, root, "act", "status: active", "branch: feat")
	task(t, root, "rdy", "status: ready", "branch: feat")
	task(t, root, "paused", "status: active", "branch: feat", "paused: true")
	task(t, root, "done", "status: consolidated", "branch: feat")
	task(t, root, "other", "status: active", "branch: elsewhere")
	write(t, root, ".ai/workspace/tasks/not valid/state", "status: active\nbranch: feat\n")
	write(t, root, ".ai/workspace/tasks/nostate/task.md", "x")
	got, err := taskCandidates(Project{Root: root}, "feat")
	if err != nil || len(got) != 2 || got[0] != "act" || got[1] != "rdy" {
		t.Errorf("%v %v", got, err)
	}
}

func TestTaskCandidatesRefuseTheStagingFlowForAReadyTask(t *testing.T) {
	root := fixture(t)
	write(t, root, ".ai/config.yaml", "git.flow: staging\n")
	task(t, root, "rdy", "status: ready", "branch: feat")
	if _, err := taskCandidates(Project{Root: root}, "feat"); err == nil {
		t.Error("a ready task on the staging flow must not be guessed at")
	}
}

func TestTaskCurrentOutcomes(t *testing.T) {
	root := fixture(t)
	ctx, _ := ctxFor(root, "feat", nil, nil)
	p := Project{Root: root}
	cur, err := taskCurrent(ctx, p)
	if err != nil || cur.Status != 1 || cur.Stderr != "jig: warning: no current task for branch: feat\n" {
		t.Errorf("none: %+v %v", cur, err)
	}
	task(t, root, "one", "status: active", "branch: feat")
	cur, _ = taskCurrent(ctx, p)
	if cur.Status != 0 || cur.ID != "one" {
		t.Errorf("one: %+v", cur)
	}
	// A detached HEAD is the branch named "detached".
	x, _ := proc.Fake(map[string]proc.Reply{gitKey(root, "symbolic-ref", "--short", "HEAD"): {Code: 128}})
	ctx.Exec = x
	cur, _ = taskCurrent(ctx, p)
	if cur.Status != 1 || cur.Stderr != "jig: warning: no current task for branch: detached\n" {
		t.Errorf("detached: %+v", cur)
	}
}

func TestTaskBase(t *testing.T) {
	root := fixture(t)
	p := Project{Root: root}
	if got := taskBase(p, ""); got != "main" {
		t.Errorf("default %q", got)
	}
	write(t, root, ".ai/config.yaml", "git.base_branch: develop # trunk\n")
	task(t, root, "t", "status: active", "base_branch: epic/x")
	task(t, root, "u", "status: active", "base_branch:")
	if taskBase(p, "t") != "epic/x" || taskBase(p, "u") != "develop" || taskBase(p, "../x") != "develop" {
		t.Errorf("%q %q", taskBase(p, "t"), taskBase(p, "u"))
	}
}
