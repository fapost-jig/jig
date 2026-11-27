package core

import (
	"fmt"
	"sort"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/errs"
	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// taskBase is jig_task_base: the branch a task was cut from, else the
// configured base. An id that is not a task id gets the configured one.
func taskBase(p Project, id string) string {
	if v, _ := storage.TaskStateGet(p.Root, id, "base_branch"); v != "" {
		return v
	}
	return storage.CfgLayered(p.Root, "git.base_branch", false, "main")
}

// currentBranch is _task_current_branch: the checked-out branch or "detached".
func currentBranch(ctx Ctx, p Project) string {
	r, err := ctx.Exec.Git(p.Root, "symbolic-ref", "--short", "HEAD")
	if err != nil || r.Code != 0 {
		return "detached"
	}
	return strings.TrimRight(r.Stdout, "\n")
}

// taskCandidates is _task_candidates_for_branch: the ids, sorted, of the tasks
// whose branch is branch, whose status is active or ready and which are not
// paused. A ready task on the staging flow may be parked, which this port does
// not read yet: that is a refusal, not a guess.
func taskCandidates(p Project, branch string) ([]string, error) {
	var list []string
	ready := false
	for _, id := range storage.TaskIDsWithState(p.Root) {
		if br, _ := storage.TaskStateGet(p.Root, id, "branch"); br != branch {
			continue
		}
		st, _ := storage.TaskStateGet(p.Root, id, "status")
		if st != "active" && st != "ready" {
			continue
		}
		if paused, _ := storage.TaskStateGet(p.Root, id, "paused"); paused == "true" {
			continue
		}
		if st == "ready" {
			ready = true
		}
		list = append(list, id)
	}
	if ready && storage.CfgLayered(p.Root, "git.flow", false, "direct") == "staging" {
		return nil, errs.New(errs.Failed, "a ready task on the staging flow may be parked, which this implementation does not read yet")
	}
	sort.Strings(list)
	return list, nil
}

// currentTask is what task_current answers: the id and exit status 0 for one
// candidate; status 1 for none and status 2 for several, with the listing it
// prints on stderr.
type currentTask struct {
	ID     string
	Status int
	Stderr string
}

// taskCurrent is task_current for the checkout p.
func taskCurrent(ctx Ctx, p Project) (currentTask, error) {
	branch := currentBranch(ctx, p)
	cands, err := taskCandidates(p, branch)
	if err != nil {
		return currentTask{}, err
	}
	switch len(cands) {
	case 0:
		return currentTask{Status: 1, Stderr: fmt.Sprintf("jig: warning: no current task for branch: %s\n", branch)}, nil
	case 1:
		return currentTask{ID: cands[0]}, nil
	}
	var b strings.Builder
	for _, id := range cands {
		st, _ := storage.TaskStateGet(p.Root, id, "status")
		upd, _ := storage.TaskStateGet(p.Root, id, "updated_at")
		fmt.Fprintf(&b, "%s  %s  updated_at=%s\n", id, st, upd)
	}
	return currentTask{Status: 2, Stderr: b.String()}, nil
}
