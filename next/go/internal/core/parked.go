package core

import (
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// parkedIDs is _task_parked_read, as far as the candidates need it: which of the
// ready tasks ids are parked at the staging branch (a task waiting for a review
// or for "prepare for prod"), derived from git and the forge cache and stored
// nowhere (adr-20261112-a-task-waiting-at-staging-is-parked-and-resuming-it-is-its-status).
// Off a sound staging flow nothing is parked.
func parkedIDs(ctx Ctx, p Project, ids []string) map[string]bool {
	parked := map[string]bool{}
	if len(ids) == 0 || storage.CfgLayered(p.Root, "git.flow", false, "direct") != "staging" {
		return parked
	}
	staging, ok := stagingInUse(ctx, p)
	if !ok {
		return parked
	}
	defaultBase := storage.CfgLayered(p.Root, "git.base_branch", false, "main")
	var rows []parkRow
	for _, id := range ids {
		st, _ := storage.TaskStateGet(p.Root, id, "status")
		branch, _ := storage.TaskStateGet(p.Root, id, "branch")
		if st != "ready" || branch == "" {
			continue
		}
		base := taskBase(p, id)
		if base != defaultBase {
			continue
		}
		pr, _ := storage.TaskStateGet(p.Root, id, "pr_url")
		pm, _ := storage.TaskStateGet(p.Root, id, "promote_url")
		rs, _ := storage.TaskStateGet(p.Root, id, "park_resumed_at")
		rows = append(rows, parkRow{id, branch, base, dash(pr), dash(pm), dash(rs)})
	}
	if len(rows) == 0 {
		return parked
	}
	land := storage.CfgLayered(p.Root, "git.staging_land", false, "pr")
	cache := forgeCacheLines(ctx, p)
	states := stagingStates(ctx, p, staging, rows)
	for _, id := range parkedStates(staging, land, rows, cache, states) {
		parked[id] = true
	}
	return parked
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

type parkRow struct{ id, branch, base, pr, pm, rs string }

// stagingInUse is jig_staging_in_use for the staging flow: the staging branch's
// name when the project's choice of flow has no fault (jig_git_flow_problems).
func stagingInUse(ctx Ctx, p Project) (string, bool) {
	branch := storage.CfgLayered(p.Root, "git.staging_branch", false, "")
	switch {
	case branch == "":
		return "", false
	case !checkRefFormat(ctx, p, branch):
		return "", false
	case strings.HasPrefix(branch, "refs/") || strings.HasPrefix(branch, "origin/"):
		return "", false
	case branch == storage.CfgLayered(p.Root, "git.base_branch", false, "main"):
		return "", false
	}
	if !oneOf(storage.CfgLayered(p.Root, "git.staging_land", false, "pr"), "pr", "external") ||
		!oneOf(storage.CfgLayered(p.Root, "git.staging_review", false, "ask"), "ask", "require", "none") ||
		!oneOf(storage.CfgLayered(p.Root, "git.promote_merge", false, "human"), "human", "auto") {
		return "", false
	}
	return branch, true
}

func oneOf(v string, ok ...string) bool {
	for _, o := range ok {
		if v == o {
			return true
		}
	}
	return false
}

func checkRefFormat(ctx Ctx, p Project, branch string) bool {
	r, err := ctx.Exec.Git(p.Root, "check-ref-format", "--branch", branch)
	return err == nil && r.Code == 0
}

// forgeCacheLines is forgecache_read: the cache's lines, comments left out. A
// checkout that borrows the tasks directory of another worktree reads that
// worktree's cache (forgecache_file).
func forgeCacheLines(ctx Ctx, p Project) []string {
	dir := storage.RuntimeDir(p.Root)
	tasks := storage.TasksDirPath(p.Root)
	if storage.IsSymlink(tasks) {
		if real := storage.PhysicalDir(tasks); real != "" && worktreeHolds(ctx, p, real, storage.TasksRel) {
			dir = storage.RuntimeDirOfTasks(real)
		}
	}
	text, ok := storage.ReadText(dir + "/forge-cache")
	if !ok {
		return nil
	}
	var out []string
	for _, l := range splitFileLines(text) {
		if l != "" && !strings.HasPrefix(l, "#") {
			out = append(out, l)
		}
	}
	return out
}

type stagingWalk struct {
	id, tip, base string
}

// stagingStates is jig_staging_states: for each task whose own work reached
// origin's staging branch, "on" (every own commit not on it is a merge of the
// base) or "behind"; nothing for the others. The graph is walked from one
// for-each-ref and, per distinct base, two rev-lists (_jig_staging_walk).
func stagingStates(ctx Ctx, p Project, staging string, rows []parkRow) map[string]string {
	states := map[string]string{}
	r, err := ctx.Exec.Git(p.Root, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/"+staging+"^{commit}")
	if err != nil || r.Code != 0 {
		return states
	}
	stip := strings.TrimRight(r.Stdout, "\n")
	if stip == "" {
		return states
	}
	refs := map[string]string{}
	for _, l := range gitLines(ctx, p.Root, "for-each-ref", "--format=R%09%(refname)%09%(objectname)", "refs/heads", "refs/remotes/origin") {
		f := strings.Split(l, "\t")
		if len(f) >= 3 && f[0] == "R" {
			refs[f[1]] = f[2]
		}
	}
	type task struct{ id, tip, base, bsha string }
	var tasks []task
	for _, row := range rows {
		if row.id == "" || row.branch == "" || row.base == "" {
			continue
		}
		tip := refs["refs/heads/"+row.branch]
		if tip == "" {
			tip = refs["refs/remotes/origin/"+row.branch]
		}
		bsha := refs["refs/remotes/origin/"+row.base]
		if bsha == "" {
			bsha = refs["refs/heads/"+row.base]
		}
		if tip != "" && bsha != "" {
			tasks = append(tasks, task{row.id, tip, row.base, bsha})
		}
	}
	type key struct{ base, sha string }
	own := map[key]bool{}
	on := map[key]bool{}
	parents := map[key][]string{}
	seenBase := map[[2]string]bool{}
	for _, t := range tasks {
		bk := [2]string{t.base, t.bsha}
		if seenBase[bk] {
			continue
		}
		seenBase[bk] = true
		var tips []string
		for _, u := range tasks {
			if u.base == t.base {
				tips = append(tips, u.tip)
			}
		}
		for _, l := range gitLines(ctx, p.Root, append(append([]string{"rev-list", "--parents"}, tips...), "^"+t.bsha)...) {
			if l == "" {
				continue
			}
			a := strings.Split(l, " ")
			k := key{t.base, a[0]}
			own[k] = true
			parents[k] = a[1:]
		}
		for _, l := range gitLines(ctx, p.Root, "rev-list", stip, "^"+t.bsha) {
			if l != "" {
				on[key{t.base, l}] = true
			}
		}
	}
	for _, t := range tasks {
		b := t.base
		if !own[key{b, t.tip}] {
			continue
		}
		seen := map[string]bool{}
		stack := []string{t.tip}
		reached, behind := false, false
		for len(stack) > 0 {
			c := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			if seen[c] {
				continue
			}
			seen[c] = true
			k := key{b, c}
			if on[k] {
				reached = true
				continue
			}
			par := parents[k]
			mine := len(par) <= 1
			for j := 1; j < len(par); j++ {
				pk := key{b, par[j]}
				if own[pk] && !on[pk] {
					mine = true
				}
			}
			if mine {
				behind = true
			}
			for j, pc := range par {
				pk := key{b, pc}
				if !own[pk] || seen[pc] {
					continue
				}
				if j > 0 && on[pk] {
					continue
				}
				stack = append(stack, pc)
			}
		}
		if reached {
			if behind {
				states[t.id] = "behind"
			} else {
				states[t.id] = "on"
			}
		}
	}
	return states
}

// parkedStates is jig_parked_states: the ids of the rows that wait at the
// staging branch, in row order.
func parkedStates(staging, land string, rows []parkRow, cache []string, states map[string]string) []string {
	type bk struct{ head, base string }
	first := map[bk]string{}
	byurl := map[string]string{}
	urlbase := map[string]string{}
	for _, l := range cache {
		f := strings.Split(l, "\t")
		field := func(n int) string {
			if n < len(f) {
				return f[n]
			}
			return ""
		}
		k := bk{field(0), field(1)}
		if _, ok := first[k]; !ok {
			first[k] = field(2)
		}
		if u := field(6); u != "" && u != "-" {
			if _, ok := byurl[u]; !ok {
				byurl[u], urlbase[u] = field(2), field(1)
			}
		}
	}
	var out []string
	for _, r := range rows {
		if r.rs != "" && r.rs != "-" {
			continue
		}
		if s := first[bk{r.branch, r.base}]; s == "open" || s == "merged" {
			continue
		}
		if pm := r.pm; pm != "" && pm != "-" {
			st, in := byurl[pm]
			if !in || st == "open" || st == "merged" {
				continue
			}
		}
		if states[r.id] == "on" {
			out = append(out, r.id)
			continue
		}
		s := ""
		u := r.pr
		if _, in := byurl[u]; u != "" && u != "-" && (!in || urlbase[u] == staging) {
			if in {
				s = byurl[u]
			} else if land == "pr" {
				s = "open"
			}
		} else {
			s = first[bk{r.branch, staging}]
		}
		if s == "open" {
			out = append(out, r.id)
		}
	}
	return out
}
