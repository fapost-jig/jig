package core

import (
	"fmt"
	"sort"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// ledger is the context file of a task: `<hash><TAB><path>[<TAB><stage>]` per
// acknowledged document.
type ledger struct {
	hash  map[string]string
	stage map[string]string
}

func ledgerFile(p Project, id string) (string, error) {
	dir, err := taskDirOf(p.Root, id)
	return dir + "/context", err
}

// readLedger reads the task's ledger; ok is false when there is none. A path
// that is in the ledger twice keeps its last line, as the awk that reads it does.
func readLedger(p Project, id string) (ledger, bool) {
	file, err := ledgerFile(p, id)
	if err != nil {
		return ledger{}, false
	}
	text, ok := storage.ReadText(file)
	if !ok || !storage.IsFile(file) {
		return ledger{}, false
	}
	l := ledger{hash: map[string]string{}, stage: map[string]string{}}
	for _, line := range splitFileLines(text) {
		f := strings.Split(line, "\t")
		path := ""
		if len(f) > 1 {
			path = f[1]
		}
		l.hash[path] = f[0]
		if len(f) >= 3 && f[2] != "" {
			l.stage[path] = f[2]
		} else {
			l.stage[path] = "-"
		}
	}
	return l, true
}

// trackedRows is _ctx_tracked_rows: every path whose reading is tracked with
// the reason it is, one row per path, sorted.
func trackedRows(p Project, s *ctxSel, rows []ctxRow) []ctxRow {
	var all []ctxRow
	for _, g := range storage.GlobalDocs() {
		if storage.IsFile(p.Root + "/.ai/knowledge/" + g) {
			all = append(all, ctxRow{".ai/knowledge/" + g, "global"})
		}
	}
	all = append(all, readRows(p, rows)...)
	for _, d := range linkedDocs(p, s.task) {
		all = append(all, ctxRow{d, "linked"})
	}
	seen := map[string]bool{}
	var out []ctxRow
	for _, r := range all {
		if r.rel == "" && r.reason == "" || seen[r.rel] {
			continue
		}
		seen[r.rel] = true
		out = append(out, r)
	}
	sortRows(out)
	return out
}

// pendingPaths is _ctx_pending_paths: tracked documents with no
// acknowledgement, or whose content has changed since one.
func pendingPaths(h *hasher, p Project, tracked []ctxRow, l ledger, haveLedger bool) ([]string, error) {
	var paths []string
	for _, r := range tracked {
		if r.rel != "" {
			paths = append(paths, r.rel)
		}
	}
	if len(paths) == 0 {
		return nil, nil
	}
	hs, err := h.hashPaths(paths)
	if err != nil {
		return nil, err
	}
	var pending []string
	for _, w := range hs {
		have := ""
		if haveLedger {
			have = l.hash[w.path]
		}
		if have != w.hash {
			pending = append(pending, w.path)
		}
	}
	return pending, nil
}

// guardAttribution is _ctx_guard_attribution: whose acknowledgements a passing
// guard took, one line per stage they were made at.
func guardAttribution(l ledger, haveLedger bool, s *ctxSel, tracked []ctxRow) string {
	if !haveLedger {
		return ""
	}
	n := map[string]int{}
	for _, r := range tracked {
		if r.rel == "" {
			continue
		}
		st, ok := l.stage[r.rel]
		if !ok {
			st = "-"
		}
		n[st]++
	}
	var lines []string
	for k, v := range n {
		lines = append(lines, fmt.Sprintf("%s\t%d", k, v))
	}
	sort.Strings(lines)
	var b strings.Builder
	here := false
	for _, line := range lines {
		stage, count, _ := strings.Cut(line, "\t")
		if stage == "-" {
			fmt.Fprintf(&b, "  %s acknowledged at no stage\n", count)
			continue
		}
		fmt.Fprintf(&b, "  %s acknowledged at %s\n", count, stage)
		if stage == s.stage {
			here = true
		}
	}
	if s.stage != "" && !here {
		fmt.Fprintf(&b, "  none acknowledged at %s: this guard passed on acknowledgements made elsewhere\n", s.stage)
	}
	return b.String()
}
