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

// refDir is jig_task_ref_dir: the directory of the referenced task or spec in
// the neighbouring repository, or why it is not there.
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
		d := abs + "/" + storage.AiDir + "/specs/" + r.id
		if !storage.IsFile(d+"/spec.md") && !storage.IsFile(d+"/roadmap.md") {
			return "", "no spec " + r.id + " in " + abs
		}
		return d, ""
	}
	d := storage.TaskDirPath(abs, r.id)
	if !storage.IsFile(d + "/task.md") {
		return "", "no task " + r.id + " in " + abs + " (a task workspace exists only in the clone that filed it)"
	}
	return d, ""
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
	md, ok := storage.ReadText(storage.TaskDirPath(p.Root, id) + "/task.md")
	if !ok || !storage.IsFile(storage.TaskDirPath(p.Root, id)+"/task.md") {
		return nil
	}
	own := storage.PhysicalDir(storage.TaskDirPath(p.Root, id))
	var rows []linkRow
	for _, ref := range taskLinks(md) {
		r, why := parseTaskRef(ref)
		if why != "" {
			rows = append(rows, linkRow{"-", ref, "malformed link: " + why + "; the form is <repo>#<task-id> or <repo>#spec/<spec-id>"})
			continue
		}
		dir, why := refDir(p, r)
		if why != "" {
			rows = append(rows, linkRow{"-", ref, why})
			continue
		}
		if r.kind == "task" && own != "" && storage.PhysicalDir(dir) == own {
			rows = append(rows, linkRow{"-", ref, "this is the task itself"})
			continue
		}
		files := append([]string{"task.md"}, workspaceArtifacts...)
		if r.kind == "spec" {
			files = []string{"spec.md", "roadmap.md"}
		}
		for _, f := range files {
			if storage.IsFile(dir + "/" + f) {
				rows = append(rows, linkRow{dir + "/" + f, ref, ""})
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
