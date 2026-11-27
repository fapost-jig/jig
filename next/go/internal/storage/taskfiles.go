package storage

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
)

// IsAbs reports whether a path, in the form storage hands out (`/` separators),
// is absolute: it starts with `/`, or with a drive letter, a colon and a
// separator (`C:/…`, `C:\…`). The one test every caller uses to tell an absolute
// path from a repository-relative one.
func IsAbs(p string) bool {
	if strings.HasPrefix(p, "/") {
		return true
	}
	return len(p) >= 3 && (p[0] >= 'a' && p[0] <= 'z' || p[0] >= 'A' && p[0] <= 'Z') && p[1] == ':' && (p[2] == '/' || p[2] == '\\')
}

// TaskFilePath is where the file name is in task id's workspace, built on the
// validating TaskDirPath; an invalid id has no path.
func TaskFilePath(root, id, name string) (string, error) {
	dir, err := TaskDirPath(root, id)
	if err != nil {
		return "", err
	}
	return dir + "/" + name, nil
}

// TaskWorkspaceFileRel is the project-relative path of a file of task id's
// workspace.
func TaskWorkspaceFileRel(id, name string) (string, error) {
	dir, err := TaskWorkspaceRel(id)
	if err != nil {
		return "", err
	}
	return dir + "/" + name, nil
}

// TaskDoc is the text of a file of task id's workspace (`task.md`, an
// artifact); ok is false when the task has no such file.
func TaskDoc(root, id, name string) (string, bool) {
	path, err := TaskFilePath(root, id, name)
	if err != nil || !isFile(path) {
		return "", false
	}
	return ReadText(path)
}

// TaskDirIsLink reports whether task id's workspace directory is a symbolic link.
func TaskDirIsLink(root, id string) bool {
	dir, err := TaskDirPath(root, id)
	return err == nil && IsSymlink(dir)
}

// TaskDirPhysical is task id's workspace directory with links resolved, "" when
// it cannot be.
func TaskDirPhysical(root, id string) string {
	dir, err := TaskDirPath(root, id)
	if err != nil {
		return ""
	}
	return PhysicalDir(dir)
}

const (
	ledgerName = "context"
	cacheName  = "context-cache"
)

// LedgerRead is the text of the task's context ledger; ok is false when it has
// none. An invalid id is an error.
func LedgerRead(root, id string) (text string, ok bool, err error) {
	path, err := TaskFilePath(root, id, ledgerName)
	if err != nil {
		return "", false, err
	}
	if !isFile(path) {
		return "", false, nil
	}
	text, ok = ReadText(path)
	return text, ok, nil
}

// LedgerWrite replaces the task's context ledger, through a temporary file and a
// rename.
func LedgerWrite(root, id, body string) error {
	path, err := TaskFilePath(root, id, ledgerName)
	if err != nil {
		return err
	}
	if !WriteFileTmp(path, body) {
		return fmt.Errorf("cannot write %s", path)
	}
	return nil
}

// CacheRead is the text of the task's required-rows cache.
func CacheRead(root, id string) (string, bool) {
	path, err := TaskFilePath(root, id, cacheName)
	if err != nil {
		return "", false
	}
	return ReadText(path)
}

// CacheWrite replaces the task's required-rows cache; a cache is optional, so
// whether it was written is all that is said.
func CacheWrite(root, id, body string) bool {
	path, err := TaskFilePath(root, id, cacheName)
	return err == nil && WriteFileTmp(path, body)
}

// TakenRecordPath is `runtime/taken/<id>/<session>` of the clone at cloneRoot:
// both names are checked as ids, and a name that is not one builds no path.
func TakenRecordPath(cloneRoot, id, session string) (string, error) {
	if !ValidID(id) || !ValidID(session) {
		return "", fmt.Errorf("%w: %s/%s", ErrInvalidID, id, session)
	}
	return RuntimeDir(cloneRoot) + "/taken/" + id + "/" + session, nil
}

// WorkingRecordPath is `runtime/working/<name>` of the checkout at root.
func WorkingRecordPath(root, name string) (string, error) {
	if !ValidID(name) {
		return "", fmt.Errorf("%w: %s", ErrInvalidID, name)
	}
	return RuntimeDir(root) + "/working/" + name, nil
}

// TakenRecordsOf are the files `runtime/taken/*/<session>` of the clone at
// cloneRoot, in the order of the shell's glob; none for a session that is not an
// id.
func TakenRecordsOf(cloneRoot, session string) []string {
	if !ValidID(session) {
		return nil
	}
	var out []string
	for _, name := range DirEntryNames(RuntimeDir(cloneRoot) + "/taken") {
		if strings.HasPrefix(name, ".") {
			continue
		}
		p, err := TakenRecordPath(cloneRoot, name, session)
		if err == nil && isFile(filepath.FromSlash(p)) {
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}
