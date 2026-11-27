package storage

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/clock"
)

// AiDir is the directory a project keeps Jig's files in (JIG_AI_DIR).
const AiDir = ".ai"

// CloneRoot is the main checkout of the clone root belongs to
// (jig_config_clone_root).
func CloneRoot(root string) string { return Slash(cloneRoot(root)) }

// RuntimeDir is root's own .ai/runtime directory.
func RuntimeDir(root string) string { return Slash(filepath.Join(root, AiDir, "runtime")) }

// RecordGet is _jig_checkout_read: the value of the first `<key>: <value>` line
// of a flat record, a CR at a line's end removed. found is false when there is
// no such file or line.
func RecordGet(file, key string) (value string, found bool) {
	f, err := os.Open(file)
	if err != nil {
		return "", false
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return "", false
	}
	prefix := key + ": "
	r := bufio.NewReader(f)
	for {
		line, err := r.ReadString('\n')
		line = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
		if rest, ok := strings.CutPrefix(line, prefix); ok {
			return rest, true
		}
		if err != nil {
			return "", false
		}
	}
}

// RecordDropKey is the body of a flat record without its `<key>: ` lines, every
// line ended by a newline and a CR at a line's end removed
// (_jig_checkout_revive's rewrite).
func RecordDropKey(file, key string) (string, bool) {
	data, err := os.ReadFile(file)
	if err != nil {
		return "", false
	}
	var b strings.Builder
	for _, line := range splitLines(string(data)) {
		line = strings.TrimSuffix(line, "\r")
		if strings.HasPrefix(line, key+": ") {
			continue
		}
		b.WriteString(line + "\n")
	}
	return b.String(), true
}

// WriteRecord is _jig_checkout_write: the body goes to `.tmp.<name>.<pid>` in
// the file's directory and is renamed over the file, so a reader sees the old
// record or the new one. It reports whether the record was written; it never
// fails a command.
func WriteRecord(file, body string) bool {
	dir, base := filepath.Split(file)
	tmp := filepath.Join(dir, ".tmp."+base+"."+strconv.Itoa(os.Getpid()))
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		return false
	}
	if _, err := f.WriteString(body); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return false
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return false
	}
	if err := os.Rename(tmp, file); err != nil {
		_ = os.Remove(tmp)
		return false
	}
	return true
}

// MakeDir is `[ -d dir ] || mkdir -p dir`.
func MakeDir(dir string) bool {
	if isDir(dir) {
		return true
	}
	return os.MkdirAll(dir, 0o755) == nil
}

// MTime is the modification time of path in seconds since the epoch.
func MTime(path string) (int64, bool) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, false
	}
	return info.ModTime().Unix(), true
}

// TakenRecordsOf are the files `runtime/taken/*/<session>` of the clone at
// cloneRoot, in the order of the shell's glob.
func TakenRecordsOf(cloneRoot, session string) []string {
	dirs, err := os.ReadDir(filepath.Join(RuntimeDir(cloneRoot), "taken"))
	if err != nil {
		return nil
	}
	var out []string
	for _, d := range dirs {
		if strings.HasPrefix(d.Name(), ".") {
			continue
		}
		p := filepath.Join(RuntimeDir(cloneRoot), "taken", d.Name(), session)
		if isFile(p) {
			out = append(out, Slash(p))
		}
	}
	sort.Strings(out)
	return out
}

// TaskHasState reports whether task id of project root has a state file. The id
// is valid: the caller checked it.
func TaskHasState(root, id string) bool {
	path, err := TaskStatePath(root, id)
	return err == nil && isFile(path)
}

// TaskIDsWithState are the ids of the workspaces of root that hold a state
// file and are well-formed ids: the glob `tasks/*/` of the shell readers.
func TaskIDsWithState(root string) []string {
	base := filepath.Join(root, AiDir, "workspace", "tasks")
	entries, err := os.ReadDir(base)
	if err != nil {
		return nil
	}
	var ids []string
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") || !ValidID(name) {
			continue
		}
		if isFile(filepath.Join(base, name, "state")) {
			ids = append(ids, name)
		}
	}
	sort.Strings(ids)
	return ids
}

// TaskFileExists reports whether the task's workspace holds the regular file
// name.
func TaskFileExists(root, id, name string) bool {
	dir, err := TaskDirPath(root, id)
	return err == nil && isFile(filepath.Join(dir, name))
}

// ReadText is the text of the file at path.
func ReadText(path string) (string, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// ManifestHeader is manifest_header_get: the value of a `key: value` line above
// the `---` separator of the project's manifest.
func ManifestHeader(root, key string) string {
	text, ok := ReadText(filepath.Join(root, AiDir, "manifest"))
	if !ok {
		return ""
	}
	for _, line := range splitLines(text) {
		line = strings.TrimSuffix(line, "\r")
		if line == "---" {
			return ""
		}
		if rest, ok := strings.CutPrefix(line, key+":"); ok {
			return strings.TrimPrefix(rest, " ")
		}
	}
	return ""
}

// CfgLayered is cfg for a key that is not local-only: the local file of the
// clone when the key may be set there (localKey), then the project's
// config.yaml, then def. An empty value falls through.
func CfgLayered(root, key string, localKey bool, def string) string {
	if localKey {
		if c, err := ReadCfgFile(filepath.Join(cloneRoot(root), AiDir, "config.local.yaml")); err == nil {
			if v, found := c.Get(key); found && v != "" {
				return v
			}
		}
	}
	if c, err := ReadConfig(root); err == nil {
		if v, found := c.Get(key); found && v != "" {
			return v
		}
	}
	return def
}

// HasConfig reports whether root holds .ai/config.yaml.
func HasConfig(root string) bool { return isFile(filepath.Join(root, AiDir, "config.yaml")) }

// TaskWorkspaceRel is the project-relative directory of task id's workspace;
// an invalid id has none.
func TaskWorkspaceRel(id string) (string, error) {
	if !ValidID(id) {
		return "", fmt.Errorf("%w: %s", ErrInvalidID, id)
	}
	return TasksRel + "/" + id, nil
}

// TasksRel is the project-relative directory that holds every task workspace.
const TasksRel = AiDir + "/workspace/tasks"

// WriteFileTmp writes body to `<path>.tmp.<pid>` and renames it over path, the
// way the shell writers do (`tmp` then `mv`), with the file mode a redirect
// gives. It reports whether the file was written.
func WriteFileTmp(path, body string) bool {
	tmp := path + ".tmp." + strconv.Itoa(os.Getpid())
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		return false
	}
	if _, err := f.WriteString(body); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return false
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return false
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return false
	}
	return true
}

// IsSymlink reports whether path is itself a symbolic link.
func IsSymlink(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.Mode()&os.ModeSymlink != 0
}

// TasksDirPath is the directory that holds every task workspace of root.
func TasksDirPath(root string) string {
	return Slash(filepath.Join(root, AiDir, "workspace", "tasks"))
}

// DirEntryNames are the names in dir, sorted; none when it cannot be read.
func DirEntryNames(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	return names
}

// AutopilotLog is _task_autopilot_log: one `<UTC>\t<event>\t<text>` line
// appended to the task's autopilot journal through a copy and a rename, and the
// clone's revision raised. The task's directory has been checked by the caller.
func AutopilotLog(root, id, event, text string, clk clock.Clock) error {
	dir, err := TaskDirPath(root, id)
	if err != nil {
		return err
	}
	file := dir + "/autopilot"
	old, _ := ReadText(file)
	if !WriteFileTmp(file, old+clk.UTC()+"\t"+event+"\t"+text+"\n") {
		return fmt.Errorf("cannot write %s", file)
	}
	return RevisionBump(root, clk)
}

// RuntimeDirOfTasks is the runtime directory beside a borrowed tasks directory
// (forgecache_file): `<ai>/runtime` for `<ai>/workspace/tasks`.
func RuntimeDirOfTasks(tasks string) string {
	return strings.TrimSuffix(tasks, "/workspace/tasks") + "/runtime"
}
