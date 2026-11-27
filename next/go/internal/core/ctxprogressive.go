package core

import (
	"fmt"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/errs"
	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// ctxResolve is ctx_resolve: the documents required before a change, what else
// the catalog offers, the task's own documents, its links and its queue place.
func ctxResolve(ctx Ctx, p Project, args []string, out *Output) error {
	s, err := parseSelectors(ctx, p, args, out)
	if err != nil {
		return err
	}
	// Only a task named with --task: one guessed from the branch is not a
	// declared entry into a stage.
	if s.taskNamed && s.stage != "" && honourPause(ctx, p, s.task, s.stage, out) {
		return nil
	}
	rows, err := requiredRows(ctx, p, s)
	if err != nil {
		return err
	}
	var b strings.Builder
	for _, g := range storage.GlobalDocs() {
		if storage.IsFile(p.Root + "/.ai/knowledge/" + g) {
			fmt.Fprintf(&b, "%-10s %s\n", "global:", ".ai/knowledge/"+g)
		}
	}
	for _, r := range readRows(p, rows) {
		fmt.Fprintf(&b, "%-10s %s  (%s)\n", "required:", r.rel, r.reason)
	}
	if s.catalog {
		for _, line := range catalogRows(p, s, rows) {
			rel, rest, _ := strings.Cut(line, "\t")
			id, summary, _ := strings.Cut(rest, "\t")
			// `read` folds the two tabs of a document with no id into one.
			if id == "" {
				id, summary = summary, ""
			}
			if rel != "" {
				fmt.Fprintf(&b, "%-10s %s  [%s] %s\n", "catalog:", rel, id, summary)
			}
		}
	}
	if s.task != "" {
		wdir, err := workspaceRel(s.task)
		if err != nil {
			return err
		}
		if storage.TaskFileExists(p.Root, s.task, "task.md") {
			fmt.Fprintf(&b, "%-10s %s\n", "workspace:", wdir+"/task.md")
		}
		for _, wf := range workspaceArtifacts {
			if storage.TaskFileExists(p.Root, s.task, wf) {
				fmt.Fprintf(&b, "%-10s %s\n", "workspace:", wdir+"/"+wf)
			}
		}
	}
	out.stdout(b.String())
	out.stdout(linkedLines(newHasher(ctx, p), p, s))
	if s.task != "" {
		out.stdout(queueLines(ctx, p, s.task))
	}
	return nil
}

// ctxPending is ctx_pending: the tracked documents with no acknowledgement.
func ctxPending(ctx Ctx, p Project, args []string, out *Output) error {
	s, err := parseSelectors(ctx, p, args, out)
	if err != nil {
		return err
	}
	rows, err := requiredRows(ctx, p, s)
	if err != nil {
		return err
	}
	if s.task == "" {
		if s.noTask {
			out.stdout("context pending: no task workspace; nothing tracked\n")
		}
		return nil
	}
	l, have := readLedger(p, s.task)
	pending, err := pendingPaths(newHasher(ctx, p), p, trackedRows(p, s, rows), l, have)
	if err != nil {
		return errs.New(errs.Failed, "context: could not hash the tracked documents")
	}
	for _, x := range pending {
		out.stdout(x + "\n")
	}
	return nil
}

// ctxGuard is ctx_guard: exit 1 while a tracked document is not acknowledged.
func ctxGuard(ctx Ctx, p Project, args []string, out *Output) error {
	s, err := parseSelectors(ctx, p, args, out)
	if err != nil {
		return err
	}
	rows, err := requiredRows(ctx, p, s)
	if err != nil {
		return err
	}
	if s.task == "" {
		out.stdout("context guard: no task workspace; nothing tracked\n")
		return nil
	}
	l, have := readLedger(p, s.task)
	tracked := trackedRows(p, s, rows)
	pending, err := pendingPaths(newHasher(ctx, p), p, tracked, l, have)
	if err != nil {
		return errs.New(errs.Failed, "context: could not hash the tracked documents")
	}
	if len(pending) == 0 {
		out.stdout(fmt.Sprintf("context guard: ok (%d document(s) acknowledged)\n", len(tracked)))
		out.stdout(guardAttribution(l, have, s, tracked))
		return nil
	}
	var b strings.Builder
	fmt.Fprintf(&b, "context guard: %d of %d document(s) not acknowledged:\n", len(pending), len(tracked))
	why := map[string]string{}
	for _, r := range tracked {
		why[r.rel] = r.reason
	}
	for _, x := range pending {
		if x == "" {
			continue
		}
		if why[x] != "" {
			fmt.Fprintf(&b, "  %s  (%s)\n", x, why[x])
		} else {
			fmt.Fprintf(&b, "  %s\n", x)
		}
	}
	if s.stage != "" {
		fmt.Fprintf(&b, "read them, then: jig context acknowledge --task %s --stage %s --files <list>\n", s.task, s.stage)
	} else {
		fmt.Fprintf(&b, "read them, then: jig context acknowledge --task %s --files <list>\n", s.task)
	}
	out.stderr(b.String())
	out.Code = 1
	return nil
}
