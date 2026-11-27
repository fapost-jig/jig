package core

import (
	"fmt"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// linkRow is a row of _ctx_linked_rows: a document a `Linked:` line reaches, or,
// with path "-", a link that reaches nothing and why.
type linkRow struct{ path, ref, why string }

// taskRef is jig_task_ref: a reference `<repo>#<id>` or `<repo>#spec/<id>`.
type taskRef struct{ repo, kind, id string }

func parseTaskRef(ref string) (taskRef, string) {
	switch strings.Count(ref, "#") {
	case 0:
		return taskRef{}, "no # between the repository and the id"
	case 1:
	default:
		return taskRef{}, "more than one #"
	}
	repo, id, _ := strings.Cut(ref, "#")
	switch {
	case repo == "":
		return taskRef{}, "no repository path before #"
	case strings.HasPrefix(repo, "/"), strings.HasPrefix(repo, "~"), len(repo) >= 2 && repo[1] == ':' && isLetter(repo[0]):
		return taskRef{}, "the repository path must be relative to the clone's main checkout"
	case strings.ContainsAny(repo, " \t\n\v\f\r\\"):
		return taskRef{}, "the repository path may not hold whitespace or a backslash"
	}
	kind := "task"
	if rest, ok := strings.CutPrefix(id, "spec/"); ok {
		kind, id = "spec", rest
	}
	if !storage.ValidID(id) {
		return taskRef{}, "not a valid " + kind + " id: " + id
	}
	return taskRef{repo, kind, id}, ""
}

func isLetter(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }

// refDir is jig_task_ref_dir: the neighbouring repository's root (links
// resolved) when the referenced task or spec is there in it, or why it is not.
func refDir(p Project, r taskRef) (string, string) {
	dir := storage.CloneRoot(p.Root) + "/" + r.repo
	abs := ""
	if storage.IsDir(dir) {
		abs = storage.PhysicalDir(dir)
	}
	if abs == "" {
		return "", "no repository at " + dir
	}
	if r.kind == "spec" {
		if !storage.IsFile(refFile(abs, r, "spec.md")) && !storage.IsFile(refFile(abs, r, "roadmap.md")) {
			return "", "no spec " + r.id + " in " + abs
		}
		return abs, ""
	}
	if !storage.TaskFileExists(abs, r.id, "task.md") {
		return "", "no task " + r.id + " in " + abs + " (a task workspace exists only in the clone that filed it)"
	}
	return abs, ""
}

// refFile is a file of the referenced task's workspace or spec directory in the
// repository at abs.
func refFile(abs string, r taskRef, name string) string {
	if r.kind == "spec" {
		return abs + "/" + storage.AiDir + "/specs/" + r.id + "/" + name
	}
	path, _ := storage.TaskFilePath(abs, r.id, name)
	return path
}

// taskLinks is jig_task_links: the references `Linked: <ref>` lines of a
// task.md give, trimmed.
func taskLinks(text string) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSuffix(line, "\r")
		rest, ok := strings.CutPrefix(line, "Linked:")
		if !ok || rest == "" || !strings.ContainsAny(rest[:1], " \t\v\f\r") {
			continue
		}
		v := strings.TrimSpace(rest)
		if v != "" {
			out = append(out, v)
		}
	}
	return out
}

// linkedRows is _ctx_linked_rows for task id.
func linkedRows(p Project, id string) []linkRow {
	if id == "" {
		return nil
	}
	md, ok := storage.TaskDoc(p.Root, id, "task.md")
	if !ok {
		return nil
	}
	own := storage.TaskDirPhysical(p.Root, id)
	var rows []linkRow
	for _, ref := range taskLinks(md) {
		r, why := parseTaskRef(ref)
		if why != "" {
			rows = append(rows, linkRow{"-", ref, "malformed link: " + why + "; the form is <repo>#<task-id> or <repo>#spec/<spec-id>"})
			continue
		}
		abs, why := refDir(p, r)
		if why != "" {
			rows = append(rows, linkRow{"-", ref, why})
			continue
		}
		if r.kind == "task" && own != "" && storage.TaskDirPhysical(abs, r.id) == own {
			rows = append(rows, linkRow{"-", ref, "this is the task itself"})
			continue
		}
		files := append([]string{"task.md"}, workspaceArtifacts...)
		if r.kind == "spec" {
			files = []string{"spec.md", "roadmap.md"}
		}
		for _, f := range files {
			if path := refFile(abs, r, f); storage.IsFile(path) {
				rows = append(rows, linkRow{path, ref, ""})
			}
		}
	}
	return rows
}

// linkedDocs is _ctx_linked_docs: the linked documents that exist.
func linkedDocs(p Project, id string) []string {
	var out []string
	for _, r := range linkedRows(p, id) {
		if r.path != "-" {
			out = append(out, r.path)
		}
	}
	return out
}

// linkedLines is _ctx_linked_lines: resolve's `linked:` lines.
func linkedLines(h *hasher, p Project, s *ctxSel) string {
	if s.task == "" {
		return ""
	}
	rows := linkedRows(p, s.task)
	if len(rows) == 0 {
		return ""
	}
	changed := map[string]bool{}
	if ledger, ok := readLedger(p, s.task); ok {
		var paths []string
		for _, r := range rows {
			if r.path != "-" {
				paths = append(paths, r.path)
			}
		}
		if len(paths) > 0 {
			if hs, err := h.hashPaths(paths); err == nil {
				for _, w := range hs {
					if have, in := ledger.hash[w.path]; in && have != w.hash {
						changed[w.path] = true
					}
				}
			}
		}
	}
	var b strings.Builder
	for _, r := range rows {
		switch {
		case r.path == "-":
			fmt.Fprintf(&b, "%-10s %s  unreachable: %s\n", "linked:", r.ref, r.why)
		case changed[r.path]:
			fmt.Fprintf(&b, "%-10s %s  (%s; changed since acknowledged)\n", "linked:", r.path, r.ref)
		default:
			fmt.Fprintf(&b, "%-10s %s  (%s)\n", "linked:", r.path, r.ref)
		}
	}
	return b.String()
}
