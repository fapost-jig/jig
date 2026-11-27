package storage

import (
	"path/filepath"
	"strconv"
	"strings"
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
