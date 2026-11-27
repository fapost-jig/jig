// Package storage is the only package that touches the file system.
//
// Task state is read and written by the rules of the bash implementation, byte
// for byte, because a project is read by both for as long as both exist
// (adr-20261126-jig-1-0-is-rewritten-off-bash-and-the-pilot-picks-the-language):
// the reader is jig_task_state_var, the writers are _task_state_set_into and
// _task_state_without_into (scripts/lib/common.sh, scripts/lib/task.sh).
package storage

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/clock"
)

// ValidID reports whether id is a task id (jig_valid_id): not empty, no leading
// dot or dash, only letters, digits, dots, dashes and underscores.
func ValidID(id string) bool {
	if id == "" || id[0] == '.' || id[0] == '-' {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '.', c == '_', c == '-':
		default:
			return false
		}
	}
	return true
}

// taskStatePath is where task id's state file is, under project root. The one
// place a task's path is built, so the id is checked here (RULES.md: no path
// from an unvalidated name): an invalid id builds no path.
func taskStatePath(root, id string) (string, error) {
	if !ValidID(id) {
		return "", fmt.Errorf("%w: %s", ErrInvalidID, id)
	}
	return filepath.Join(root, ".ai", "workspace", "tasks", id, "state"), nil
}

// splitLines splits text the way awk and `read -r` see a file: at each newline,
// the last line needing no newline of its own. An empty text has no lines.
func splitLines(text string) []string {
	if text == "" {
		return nil
	}
	lines := strings.Split(text, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// trimLeadingSpace drops leading [[:space:]] (_jig_task_state_trim: leading
// only; trailing blanks are part of the value).
func trimLeadingSpace(s string) string {
	return strings.TrimLeft(s, " \t\n\v\f\r")
}

// StateGet is the value of key in the state text: the first line that starts
// with `<key>:`, what follows the colon without its leading blanks. found is
// false when no line has the key.
func StateGet(text, key string) (value string, found bool) {
	prefix := key + ":"
	for _, line := range splitLines(text) {
		if strings.HasPrefix(line, prefix) {
			return trimLeadingSpace(line[len(prefix):]), true
		}
	}
	return "", false
}

// StateKeys are the keys of the state text with their values, the first line
// of a key winning. A key is what stands before the first colon of a line; a
// line with no colon has none.
func StateKeys(text string) (keys []string, values map[string]string) {
	values = map[string]string{}
	for _, line := range splitLines(text) {
		i := strings.IndexByte(line, ':')
		if i < 0 {
			continue
		}
		k := line[:i]
		if _, seen := values[k]; seen {
			continue
		}
		keys = append(keys, k)
		values[k] = trimLeadingSpace(line[i+1:])
	}
	return keys, values
}

// StateSet is the state text with key set to value and every `updated_at:`
// line refreshed to today (_task_state_set_into): every line of the key is
// replaced; a key with no line goes before the first `created_at:` line, or to
// the end. The result ends in a newline whenever it has a line, as awk's does.
func StateSet(text, key, value, today string) string {
	var b strings.Builder
	prefix := key + ":"
	done := false
	for _, line := range splitLines(text) {
		switch {
		case strings.HasPrefix(line, prefix):
			b.WriteString(key + ": " + value + "\n")
			done = true
		case !done && strings.HasPrefix(line, "created_at:"):
			b.WriteString(key + ": " + value + "\n")
			b.WriteString(line + "\n")
			done = true
		case strings.HasPrefix(line, "updated_at:"):
			b.WriteString("updated_at: " + today + "\n")
		default:
			b.WriteString(line + "\n")
		}
	}
	if !done {
		b.WriteString(key + ": " + value + "\n")
	}
	return b.String()
}

// StateWithout is the state text without the lines of every key, and with every
// `updated_at:` line refreshed to today (_task_state_without_into). A line is a
// line of a key when it has a colon and what precedes its first colon is the key.
func StateWithout(text string, keys []string, today string) string {
	drop := map[string]bool{}
	for _, k := range strings.Fields(strings.Join(keys, " ")) {
		drop[k] = true
	}
	var b strings.Builder
	for _, line := range splitLines(text) {
		if i := strings.IndexByte(line, ':'); i >= 0 && drop[line[:i]] {
			continue
		}
		if strings.HasPrefix(line, "updated_at:") {
			b.WriteString("updated_at: " + today + "\n")
			continue
		}
		b.WriteString(line + "\n")
	}
	return b.String()
}

// ErrInvalidID is returned for an id that is not a task id: no path is built
// from it.
var ErrInvalidID = errors.New("invalid task id")

// ReadTaskState is the state text of task id. A missing file is fs.ErrNotExist.
func ReadTaskState(root, id string) (string, error) {
	path, err := taskStatePath(root, id)
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// TaskStateGet is jig_task_state_var: the value of key in task id's state, found
// false when the id is not valid, the file is not there or has no such line.
// It never fails.
func TaskStateGet(root, id, key string) (value string, found bool) {
	text, err := ReadTaskState(root, id)
	if err != nil {
		return "", false
	}
	return StateGet(text, key)
}

// TaskStateSet writes key into task id's state, as StateSet builds it,
// atomically: a temporary file beside the state, then a rename. The task must
// have a state file.
func TaskStateSet(root, id, key, value string, clk clock.Clock) error {
	return rewriteState(root, id, func(text string) string {
		return StateSet(text, key, value, clk.Today())
	})
}

// TaskStateRemove removes the lines of keys from task id's state, as
// StateWithout builds it, atomically.
func TaskStateRemove(root, id string, keys []string, clk clock.Clock) error {
	return rewriteState(root, id, func(text string) string {
		return StateWithout(text, keys, clk.Today())
	})
}

func rewriteState(root, id string, build func(string) string) error {
	text, err := ReadTaskState(root, id)
	if err != nil {
		return err
	}
	path, err := taskStatePath(root, id)
	if err != nil {
		return err
	}
	return writeAtomic(path, []byte(build(text)))
}

// writeAtomic writes data to a temporary file beside path and renames it over
// path, so a reader sees the old file or the new one.
func writeAtomic(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), "state.tmp.")
	if err != nil {
		return err
	}
	tmp := f.Name()
	ok := false
	defer func() {
		if !ok {
			_ = os.Remove(tmp)
		}
	}()
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if info, err := os.Stat(path); err == nil {
		_ = os.Chmod(tmp, info.Mode().Perm())
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	ok = true
	return nil
}
