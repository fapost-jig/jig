package core

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/errs"
	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// ctxAcknowledge is ctx_acknowledge: record documents the agent states it has
// read, or with --revoke withdraw such a record. A batch is all or nothing.
func ctxAcknowledge(ctx Ctx, p Project, args []string, out *Output) error {
	var taskID, filesArg string
	filesStdin, revoke, stageGiven := false, false, false
	stage := "-"
	for i := 0; i < len(args); {
		a := args[i]
		need := func() (string, error) {
			if len(args)-i < 2 {
				return "", errs.New(errs.Failed, "context: %s requires a value", a)
			}
			return args[i+1], nil
		}
		switch a {
		case "--revoke":
			revoke = true
			i++
		case "--task", "--files", "--stage":
			v, err := need()
			if err != nil {
				return err
			}
			i += 2
			switch a {
			case "--task":
				taskID = v
			case "--files":
				if v == "-" {
					filesStdin = true
				} else {
					filesArg = v
				}
			default:
				if !validStage(v) {
					return errs.New(errs.Failed, "context: invalid stage: %s", v)
				}
				stage, stageGiven = v, true
			}
		default:
			return errs.New(errs.Failed, "context: unknown argument: %s", a)
		}
	}
	if revoke && stageGiven {
		return errs.New(errs.Failed, "context acknowledge: --revoke takes no --stage: a revoke withdraws the path's acknowledgement whatever stage it was made at")
	}
	if taskID == "" {
		return errs.New(errs.Failed, "context acknowledge: --task is required")
	}
	if !storage.ValidID(taskID) {
		return errs.New(errs.Failed, "invalid task id: %s", taskID)
	}
	if !storage.TaskHasState(p.Root, taskID) {
		return errs.New(errs.Failed, "context: unknown task: %s", taskID)
	}
	if err := guardWrite(ctx, p, taskID, "context acknowledge"); err != nil {
		return err
	}

	var files string
	switch {
	case filesStdin:
		files = readAll(ctx.Stdin)
	case filesArg != "":
		files = strings.ReplaceAll(filesArg, ",", "\n")
	default:
		return errs.New(errs.Failed, "context acknowledge: --files is required")
	}
	var given []string
	for _, l := range strings.Split(files, "\n") {
		if l != "" {
			given = append(given, l)
		}
	}
	if len(given) == 0 {
		return errs.New(errs.Failed, "context acknowledge: --files is empty")
	}

	linked := linkedDocs(p, taskID)
	ledgerPath, err := ledgerFile(p, taskID)
	if err != nil {
		return err
	}
	old, haveLedger := storage.ReadText(ledgerPath)
	haveSet := map[string]bool{}
	var oldLines []string
	if haveLedger {
		oldLines = splitFileLines(old)
		for _, l := range oldLines {
			f := strings.Split(l, "\t")
			if len(f) > 1 {
				haveSet[f[1]] = true
			}
		}
	}

	var norm, problems []string
	seen := map[string]bool{}
	for _, rel := range given {
		rel = normalisePath(p, rel, linked)
		var problem string
		if revoke {
			problem = checkRevokedPath(rel, haveSet)
		} else {
			problem = checkKnowledgePath(p, rel, linked)
		}
		if problem != "" {
			problems = append(problems, problem)
			continue
		}
		if !seen[rel] {
			seen[rel] = true
			norm = append(norm, rel)
		}
	}
	if len(problems) > 0 {
		var b strings.Builder
		for _, pr := range problems {
			b.WriteString("context acknowledge: " + pr + "\n")
		}
		out.stderr(b.String())
		return errs.New(errs.Failed, "context acknowledge: %d path(s) refused; nothing recorded. Give the paths as jig context guard prints them", len(problems))
	}

	var lines []string
	for _, l := range oldLines {
		f := strings.Split(l, "\t")
		if len(f) < 2 || f[1] == "" || seen[f[1]] {
			continue
		}
		lines = append(lines, strings.Join(nonEmptyTail(f), "\t"))
	}
	if !revoke {
		hs, err := newHasher(ctx, p).hashPaths(norm)
		if err != nil {
			return errs.New(errs.Failed, "context acknowledge: could not hash the documents")
		}
		for _, h := range hs {
			lines = append(lines, h.hash+"\t"+h.path+"\t"+stage)
		}
	}
	sort.Strings(lines)
	body := strings.Join(lines, "\n")
	if body != "" {
		body += "\n"
	}
	if !storage.WriteFileTmp(ledgerPath, body) {
		return errs.New(errs.Failed, "context acknowledge: cannot write the ledger")
	}
	switch {
	case revoke:
		out.stdout(fmt.Sprintf("revoked %d document(s) for %s\n", len(norm), taskID))
	case stage == "-":
		out.stdout(fmt.Sprintf("acknowledged %d document(s) for %s\n", len(norm), taskID))
	default:
		out.stdout(fmt.Sprintf("acknowledged %d document(s) for %s at %s\n", len(norm), taskID, stage))
	}
	return nil
}

// nonEmptyTail is a ledger line's fields as `read -r hash rel rest` keeps them:
// the hash, the path, and the rest only when it is not empty.
func nonEmptyTail(f []string) []string {
	if len(f) > 2 && strings.Join(f[2:], "\t") != "" {
		return []string{f[0], f[1], strings.Join(f[2:], "\t")}
	}
	return f[:2]
}

// normalisePath is _ctx_normalise_path_v: a leading `./` goes, and an absolute
// path inside the project, spelled physically or not, becomes
// repository-relative. A linked document's absolute path is kept.
func normalisePath(p Project, path string, linked []string) string {
	for strings.HasPrefix(path, "./") {
		path = path[2:]
	}
	if !strings.HasPrefix(path, "/") {
		return path
	}
	for _, l := range linked {
		if l == path {
			return path
		}
	}
	if rest, ok := strings.CutPrefix(path, p.Root+"/"); ok {
		return rest
	}
	if phys := storage.PhysicalDir(filepath.Dir(path)); phys != "" && strings.HasPrefix(phys+"/", p.Root+"/") {
		rel := strings.TrimPrefix(strings.TrimPrefix(phys, p.Root), "/")
		if rel != "" {
			return rel + "/" + filepath.Base(path)
		}
		return filepath.Base(path)
	}
	return path
}

const absoluteRefused = "path must be repository-relative: %s (an absolute path only for a document a Linked: line of the task reaches)"

// checkKnowledgePath is _ctx_check_knowledge_path: what is wrong with a path
// before it is acknowledged, or "".
func checkKnowledgePath(p Project, rel string, linked []string) string {
	switch {
	case strings.HasPrefix(rel, "/"):
		for _, l := range linked {
			if l == rel {
				return ""
			}
		}
		return fmt.Sprintf(absoluteRefused, rel)
	case strings.Contains(rel, ".."):
		return fmt.Sprintf("path may not contain '..': %s", rel)
	}
	if !(strings.HasPrefix(rel, ".ai/knowledge/") && strings.HasSuffix(rel, ".md")) {
		if !isLinkedSource(p, rel) {
			return fmt.Sprintf("not a knowledge document or a linked source: %s", rel)
		}
		full := p.Root + "/" + rel
		if !storage.IsFile(full) || storage.IsSymlink(full) {
			return fmt.Sprintf("no such document: %s", rel)
		}
		root := storage.PhysicalDir(p.Root)
		dir := storage.PhysicalDir(filepath.Dir(full))
		if dir == "" {
			return fmt.Sprintf("no such document: %s", rel)
		}
		if !strings.HasPrefix(dir+"/", root+"/") {
			return fmt.Sprintf("linked source leaves the repository: %s", rel)
		}
	}
	if !storage.IsFile(p.Root + "/" + rel) {
		return fmt.Sprintf("no such document: %s", rel)
	}
	return ""
}

// checkRevokedPath is _ctx_check_revoked_path: a path whose acknowledgement is
// withdrawn must be in the ledger.
func checkRevokedPath(rel string, have map[string]bool) string {
	switch {
	case strings.HasPrefix(rel, "/"):
		if !have[rel] {
			return fmt.Sprintf(absoluteRefused, rel)
		}
	case strings.Contains(rel, ".."):
		return fmt.Sprintf("path may not contain '..': %s", rel)
	}
	if !have[rel] {
		return fmt.Sprintf("not acknowledged for this task: %s", rel)
	}
	return ""
}

// isLinkedSource is _ctx_is_linked_source: a resolvable stub links rel.
func isLinkedSource(p Project, rel string) bool {
	for _, path := range storage.KnowledgeDocs(p.Root) {
		doc, ok := storage.ReadKnowledgeDoc(path)
		if !ok {
			continue
		}
		if src, _ := doc.Scalar("source"); src != rel {
			continue
		}
		if st, _ := doc.Scalar("status"); st == "active" || st == "accepted" {
			return true
		}
	}
	return false
}
