package storage

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/clock"
)

// QueuePlace is what jig_queue_place answers for a task that is in the queue.
type QueuePlace struct {
	Level    string // `-` for the top level, else `epic:<spec>`
	Priority string // `-` for none
	Rank     int
	Count    int
	Deps     []QueueDep
}

// QueueDep is something a queued task waits for.
type QueueDep struct{ On, Reason string }

// queueLines is _jig_queue_lines_v: the lines of the clone's queue, none when
// there is no queue or it is of another format version.
func queueLines(root string) []string {
	text, ok := ReadText(filepath.Join(cloneRoot(root), AiDir, "runtime", "queue"))
	if !ok {
		return nil
	}
	lines := splitLines(text)
	if len(lines) > 0 && !queueLineReadable(lines[0]) {
		return nil
	}
	return lines
}

// queueLineReadable is _jig_queue_line_readable: a `# jig queue` header whose
// fourth word is not the format this jig reads is unreadable.
func queueLineReadable(first string) bool {
	if !strings.HasPrefix(first, "# jig queue ") {
		return true
	}
	words := strings.Fields(first)
	return len(words) >= 4 && words[3] == "1"
}

// queueFileReadable is _jig_queue_readable for a file that has lines (an empty
// file is readable and holds nothing).
func queueFileReadable(root string) bool {
	_, ok := ReadText(filepath.Join(cloneRoot(root), AiDir, "runtime", "queue"))
	return ok
}

type queueRow struct {
	kind, f2, f3, f4, f5 string
}

// queueItems is jig_queue_items: each item in the order of its lines followed by
// its own dependencies in theirs.
func queueItems(lines []string) []queueRow {
	type item struct{ f [5]string }
	var items []item
	type dep struct{ sub, on, reason string }
	var deps []dep
	for _, line := range lines {
		f := strings.Split(line, "\t")
		switch {
		case f[0] == "item" && len(f) >= 5:
			items = append(items, item{[5]string{f[0], f[1], f[2], f[3], f[4]}})
		case f[0] == "dep" && len(f) >= 4:
			deps = append(deps, dep{f[1], f[2], f[3]})
		}
	}
	var rows []queueRow
	for _, it := range items {
		rows = append(rows, queueRow{"item", it.f[1], it.f[2], it.f[3], it.f[4]})
		for _, d := range deps {
			if d.sub == it.f[1] {
				rows = append(rows, queueRow{kind: "dep", f2: d.on, f3: d.reason})
			}
		}
	}
	return rows
}

// awkNumber is awk's `x + 0`: the leading number of s, 0 when there is none.
func awkNumber(s string) float64 {
	s = strings.TrimLeft(s, " \t")
	end := 0
	for end < len(s) {
		c := s[end]
		if (c >= '0' && c <= '9') || c == '.' || ((c == '-' || c == '+') && end == 0) || ((c == 'e' || c == 'E') && end > 0) {
			end++
			continue
		}
		break
	}
	for end > 0 {
		if v, err := strconv.ParseFloat(s[:end], 64); err == nil {
			return v
		}
		end--
	}
	return 0
}

// ReadQueuePlace is jig_queue_place: ok is false when the task is not an item of
// the queue, there is no queue, or it is of another format version.
func ReadQueuePlace(root, id string) (place QueuePlace, ok bool) {
	if !queueFileReadable(root) {
		return place, false
	}
	rows := queueItems(queueLines(root))
	ref := "task:" + id
	var level, pos string
	mine := false
	for _, r := range rows {
		switch r.kind {
		case "item":
			mine = false
			if r.f2 != ref {
				continue
			}
			mine = true
			level, place.Priority, pos = r.f3, r.f5, r.f4
		case "dep":
			if mine {
				place.Deps = append(place.Deps, QueueDep{On: r.f2, Reason: r.f3})
			}
		}
	}
	if level == "" {
		return place, false
	}
	place.Level = level
	before, n := 0, 0
	for _, r := range rows {
		if r.kind == "item" && r.f3 == level {
			n++
			if awkNumber(r.f4) < awkNumber(pos) {
				before++
			}
		}
	}
	place.Rank, place.Count = before+1, n
	return place, true
}

// PauseRequest is jig_pause_request: when the queue holds a pause request for
// task id, and its reason.
func PauseRequest(root, id string) (at, reason string, ok bool) {
	prefix := "request\ttask:" + id + "\tpause\t"
	for _, line := range queueLines(root) {
		rest, found := strings.CutPrefix(line, prefix)
		if !found {
			continue
		}
		at, rest, more := strings.Cut(rest, "\t")
		if more {
			reason, _, _ = strings.Cut(rest, "\t")
		}
		return at, reason, true
	}
	return "", "", false
}

// ErrNoRequest says the queue holds no such request.
var ErrNoRequest = errors.New("no such request")

// queueBeforeClaim is a hook for a test: it runs between the read of the queue
// and the claim of the revision, where another write may land.
var queueBeforeClaim = func() {}

// QueueCancelRequest is one attempt of `jig queue cancel <ref> <kind>` as
// _queue_write and _queue_commit make it: the revision is read before the
// queue, the queue is rewritten in canonical order (_queue_apply) into a
// temporary, the revision above the one read is claimed, and only then does the
// file move into place, after which the revision is raised again. A clone that
// changed meanwhile is ErrStaleRevision with the queue untouched; a queue of
// another format version, or one with no such request, is another error.
func QueueCancelRequest(root, ref, kind string, clk clock.Clock) error {
	path := filepath.Join(cloneRoot(root), AiDir, "runtime", "queue")
	expected := RevisionRead(root)
	text, _ := ReadText(path)
	out, err := queueCanonical(splitLines(text), ref, kind)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("queue: cannot create %s", filepath.Dir(path))
	}
	tmp := path + ".tmp." + strconv.Itoa(os.Getpid())
	if err := os.WriteFile(tmp, []byte(out), 0o666); err != nil {
		return fmt.Errorf("queue: cannot write %s", tmp)
	}
	queueBeforeClaim()
	if err := RevisionClaim(root, expected, clk); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("queue: cannot write %s", path)
	}
	_ = RevisionBump(root, clk)
	return nil
}

type queueItem struct {
	ref, level, pos, pri string
}

// queueCanonical is the awk of _queue_apply for op `cancel`.
func queueCanonical(lines []string, ref, kind string) (string, error) {
	var items []queueItem
	itemIdx := map[string]bool{}
	type dep struct{ sub, on, reason string }
	var deps []dep
	depIdx := map[[2]string]bool{}
	type req struct {
		sub, kind, at, reason string
		alive                 bool
	}
	var reqs []*req
	reqIdx := map[[2]string]*req{}
	var other []string
	for i, line := range lines {
		if i == 0 && strings.HasPrefix(line, "# jig queue ") {
			f := strings.Fields(line)
			if len(f) < 4 || f[3] != "1" {
				return "", errors.New("queue: another format than this jig writes")
			}
			continue
		}
		if strings.HasPrefix(line, "#") || strings.Trim(line, " \t") == "" {
			continue
		}
		f := strings.Split(line, "\t")
		field := func(n int) string {
			if n < len(f) {
				return f[n]
			}
			return ""
		}
		switch {
		case f[0] == "item" && len(f) >= 5:
			if !itemIdx[f[1]] {
				itemIdx[f[1]] = true
				items = append(items, queueItem{f[1], f[2], f[3], f[4]})
			}
		case f[0] == "dep" && len(f) >= 4:
			if k := [2]string{f[1], f[2]}; !depIdx[k] {
				depIdx[k] = true
				deps = append(deps, dep{f[1], f[2], f[3]})
			}
		case f[0] == "request" && len(f) >= 4:
			if k := [2]string{f[1], f[2]}; reqIdx[k] == nil {
				r := &req{f[1], f[2], f[3], field(4), true}
				reqIdx[k] = r
				reqs = append(reqs, r)
			}
		default:
			other = append(other, line)
		}
	}
	r := reqIdx[[2]string{ref, kind}]
	if r == nil {
		return "", ErrNoRequest
	}
	r.alive = false

	sort.SliceStable(items, func(a, b int) bool {
		x, y := items[a], items[b]
		if x.level != y.level {
			if x.level == "-" {
				return true
			}
			if y.level == "-" {
				return false
			}
			return x.level < y.level
		}
		if px, py := awkNumber(x.pos), awkNumber(y.pos); px != py {
			return px < py
		}
		return x.ref < y.ref
	})
	sort.SliceStable(deps, func(a, b int) bool {
		if deps[a].sub != deps[b].sub {
			return deps[a].sub < deps[b].sub
		}
		return deps[a].on < deps[b].on
	})
	sort.SliceStable(reqs, func(a, b int) bool {
		if reqs[a].sub != reqs[b].sub {
			return reqs[a].sub < reqs[b].sub
		}
		return reqs[a].kind < reqs[b].kind
	})
	var b strings.Builder
	b.WriteString("# jig queue 1 — written by `jig queue` only; do not edit by hand\n")
	for _, it := range items {
		fmt.Fprintf(&b, "item\t%s\t%s\t%.0f\t%s\n", it.ref, it.level, awkNumber(it.pos), it.pri)
	}
	for _, d := range deps {
		fmt.Fprintf(&b, "dep\t%s\t%s\t%s\n", d.sub, d.on, d.reason)
	}
	for _, q := range reqs {
		if q.alive {
			fmt.Fprintf(&b, "request\t%s\t%s\t%s\t%s\n", q.sub, q.kind, q.at, q.reason)
		}
	}
	for _, o := range other {
		b.WriteString(o + "\n")
	}
	return b.String(), nil
}
