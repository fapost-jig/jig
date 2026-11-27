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
// paused; a ready task parked at the staging branch is not one.
func taskCandidates(ctx Ctx, p Project, branch string) ([]string, error) {
	var list, ready []string
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
			ready = append(ready, id)
		}
		list = append(list, id)
	}
	// A ready task waiting at the staging branch holds no current-task slot.
	if parked := parkedIDs(ctx, p, ready); len(parked) > 0 {
		var kept []string
		for _, id := range list {
			if !parked[id] {
				kept = append(kept, id)
			}
		}
		list = kept
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
	cands, err := taskCandidates(ctx, p, branch)
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

// taskDirOf is task_dir: the task's workspace directory, and what the shell
// dies with for an id that is not one.
func taskDirOf(root, id string) (string, error) {
	d, err := storage.TaskDirPath(root, id)
	if err != nil {
		return "", errs.New(errs.Failed, "invalid task id: %s", id)
	}
	return d, nil
}

// workspaceRel is the project-relative directory of the task's workspace.
func workspaceRel(id string) (string, error) {
	d, err := storage.TaskWorkspaceRel(id)
	if err != nil {
		return "", errs.New(errs.Failed, "invalid task id: %s", id)
	}
	return d, nil
}

// guardWrite is _task_guard_write: the check every writer of a task's workspace
// passes. The tasks directory must physically be the one of a checkout of this
// repository, and the task's directory the entry named after it, or a link to
// its workspace in a worktree of this repository. The error is what the shell
// dies with, naming cmd.
func guardWrite(ctx Ctx, p Project, id, cmd string) error {
	dir, err := taskDirOf(p.Root, id)
	if err != nil {
		return err
	}
	if !storage.IsFile(dir + "/state") {
		return errs.New(errs.NotFound, "%s: unknown task: %s", cmd, id)
	}
	tasksRel := storage.TasksRel
	tasksRoot := storage.PhysicalDir(storage.TasksDirPath(p.Root))
	if tasksRoot == "" {
		return errs.New(errs.Failed, "%s: cannot inspect %s", cmd, tasksRel)
	}
	if !worktreeHolds(ctx, p, tasksRoot, tasksRel) {
		return errs.New(errs.Failed, "%s: %s leads to %s, which is no checkout of this repository", cmd, tasksRel, tasksRoot)
	}
	if storage.IsSymlink(dir) {
		real := storage.PhysicalDir(dir)
		if real == "" || !worktreeHolds(ctx, p, real, tasksRel+"/"+id) {
			return errs.New(errs.Failed, "%s: linked task workspace is unsupported unless it is this task's workspace in another worktree", cmd)
		}
		return nil
	}
	real := storage.PhysicalDir(dir)
	if real == "" {
		return errs.New(errs.Failed, "%s: cannot inspect workspace", cmd)
	}
	if real != tasksRoot+"/"+id {
		return errs.New(errs.Failed, "%s: workspace outside task root", cmd)
	}
	return nil
}

// worktreeHolds is _task_worktree_holds: want is <W>/<rel> for this checkout or
// for any worktree git lists for this repository.
func worktreeHolds(ctx Ctx, p Project, want, rel string) bool {
	if phys := storage.PhysicalDir(p.Root); phys != "" && want == phys+"/"+rel {
		return true
	}
	r, err := ctx.Exec.Git(p.Root, "worktree", "list", "--porcelain")
	if err != nil || r.Code != 0 {
		return false
	}
	for _, line := range strings.Split(r.Stdout, "\n") {
		path, ok := strings.CutPrefix(line, "worktree ")
		if !ok {
			continue
		}
		if phys := storage.PhysicalDir(path); phys != "" && want == phys+"/"+rel {
			return true
		}
	}
	return false
}
