package core

import (
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/errs"
	"github.com/fapost-jig/jig/next/go/internal/storage"
)

const ctxUsage = `usage: jig context [--task <id>] [--files <list>|-] [--domains a,b] [--all] [--format list|paths]
       jig context resolve   [selectors] [--catalog]
       jig context pending   [selectors]
       jig context guard     [selectors]
       jig context acknowledge --task <id> [--stage <stage> | --revoke] --files <list>|-

selectors: --task <id>|--no-task --stage <stage> --files <list>|- --domains a,b --topics a,b --ids a,b --all`

// workspaceArtifacts are the task documents other than task.md, in the order
// they are reported when present.
var workspaceArtifacts = []string{"discovery.md", "spec.md", "alternatives.md", "design.md", "plan.md", "review.md", "verification.md", "handoff.md"}

// Context is `jig context`: the relevant knowledge for a task.
func Context(ctx Ctx, args []string) Output {
	var out Output
	if err := runContext(ctx, args, &out); err != nil {
		out.Die(err)
	}
	return out
}

// runContext is cmd_context.
func runContext(ctx Ctx, args []string, out *Output) error {
	p, err := RequireInit(ctx)
	if err != nil {
		return err
	}
	if len(args) > 0 {
		switch w := args[0]; {
		case w == "resolve":
			return ctxResolve(ctx, p, args[1:], out)
		case w == "pending":
			return ctxPending(ctx, p, args[1:], out)
		case w == "guard":
			return ctxGuard(ctx, p, args[1:], out)
		case w == "acknowledge":
			return ctxAcknowledge(ctx, p, args[1:], out)
		case w != "" && !strings.HasPrefix(w, "-"):
			return errs.New(errs.Failed, "%s", ctxUsage)
		}
	}
	return ctxStateless(ctx, p, args, out)
}

// ctxStateless is ctx_stateless: what matches a diff, a file list or a task.
func ctxStateless(ctx Ctx, p Project, args []string, out *Output) error {
	var taskID, filesArg, domainsArg string
	noTask, filesStdin, showAll := false, false, false
	format := "list"
	for i := 0; i < len(args); {
		a := args[i]
		value := func() (string, error) {
			if len(args)-i < 2 {
				return "", errs.New(errs.Failed, "context: %s requires a value", a)
			}
			return args[i+1], nil
		}
		switch a {
		case "--task":
			v, err := value()
			if err != nil {
				return err
			}
			taskID = v
			i += 2
		case "--no-task":
			noTask = true
			i++
		case "--stage":
			return errs.New(errs.Failed, "context: --stage requires the progressive form; use jig context resolve")
		case "--files":
			v, err := value()
			if err != nil {
				return err
			}
			if v == "-" {
				filesStdin = true
			} else {
				filesArg = v
			}
			i += 2
		case "--domains":
			v, err := value()
			if err != nil {
				return err
			}
			domainsArg = v
			i += 2
		case "--all":
			showAll = true
			i++
		case "--format":
			v, err := value()
			if err != nil {
				return err
			}
			if v != "list" && v != "paths" {
				return errs.New(errs.Failed, "context: invalid --format: %s (want list or paths)", v)
			}
			format = v
			i += 2
		default:
			return errs.New(errs.Failed, "context: unknown argument: %s", a)
		}
	}

	if noTask && taskID != "" {
		return errs.New(errs.Failed, "context: --task conflicts with --no-task")
	}
	if taskID != "" {
		if !storage.ValidID(taskID) {
			return errs.New(errs.Failed, "invalid task id: %s", taskID)
		}
		if !storage.TaskHasState(p.Root, taskID) {
			return errs.New(errs.Failed, "context: unknown task: %s", taskID)
		}
	} else if !noTask {
		cur, err := taskCurrent(ctx, p)
		if err != nil {
			return err
		}
		if cur.Status == 2 {
			out.stderr(cur.Stderr)
		}
		taskID = cur.ID
	}

	var files []string
	switch {
	case filesStdin:
		files = splitFileList(readAll(ctx.Stdin))
	case filesArg != "":
		files = splitFileList(strings.ReplaceAll(filesArg, ",", "\n"))
	default:
		files = touchedFiles(ctx, p.Root, taskBase(p, taskID))
	}

	var domains []string
	if domainsArg != "" {
		domains = strings.Fields(strings.ReplaceAll(domainsArg, ",", " "))
	} else if taskID != "" {
		if d, _ := storage.TaskStateGet(p.Root, taskID, "domains"); d != "" {
			domains = strings.Fields(strings.ReplaceAll(d, ",", " "))
		}
	}

	type row struct{ label, path, reason string }
	var rows []row
	for _, g := range storage.GlobalDocs() {
		if storage.IsFile(p.Root + "/.ai/knowledge/" + g) {
			rows = append(rows, row{"global:", ".ai/knowledge/" + g, ""})
		}
	}
	matched, err := matchedDocs(p, files, domains, showAll)
	if err != nil {
		return err
	}
	for _, m := range matched {
		path, reason, _ := strings.Cut(m, "\t")
		rows = append(rows, row{"matched:", path, reason})
	}
	if taskID != "" {
		wdir, err := workspaceRel(taskID)
		if err != nil {
			return err
		}
		if storage.TaskFileExists(p.Root, taskID, "task.md") {
			rows = append(rows, row{"workspace:", wdir + "/task.md", ""})
		}
		for _, wf := range workspaceArtifacts {
			if storage.TaskFileExists(p.Root, taskID, wf) {
				rows = append(rows, row{"workspace:", wdir + "/" + wf, ""})
			}
		}
	}
	if len(rows) == 0 {
		return nil
	}

	var b strings.Builder
	for _, r := range rows {
		switch {
		case format == "paths":
			b.WriteString(r.path + "\n")
		case r.reason != "":
			fmt.Fprintf(&b, "%-10s %s  (%s)\n", r.label, r.path, r.reason)
		default:
			fmt.Fprintf(&b, "%-10s %s\n", r.label, r.path)
		}
	}
	out.stdout(b.String())
	if format != "paths" && taskID != "" {
		out.stdout(queueLines(ctx, p, taskID))
	}
	return nil
}

// readAll is `$(cat)`: the input without its trailing newlines.
func readAll(r io.Reader) string {
	if r == nil {
		return ""
	}
	data, _ := io.ReadAll(r)
	return strings.TrimRight(string(data), "\n")
}

// splitFileList is a newline-separated list, without its trailing newlines.
func splitFileList(s string) []string {
	s = strings.TrimRight(s, "\n")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

// matchedDocs is _ctx_matched_docs: "<relpath><TAB><reason>" per matching
// document, sorted. A selected stub whose source is missing is a refusal.
func matchedDocs(p Project, files, domains []string, showAll bool) ([]string, error) {
	var out []string
	for _, path := range storage.KnowledgeDocs(p.Root) {
		doc, ok := storage.ReadKnowledgeDoc(path)
		if !ok {
			continue
		}
		if load, _ := doc.Scalar("load"); load == "stage" {
			continue
		}
		if !showAll {
			status, _ := doc.Scalar("status")
			if status != "active" && status != "accepted" {
				continue
			}
		}
		reason, ok := docReason(doc, files, domains)
		if !ok {
			continue
		}
		rel := relPath(p, path)
		src, _ := doc.Scalar("source")
		if src != "" {
			if !storage.KnowledgeReadPath(p.Root, src) {
				return nil, errs.New(errs.Failed, "context: %s is selected but its source %s is missing; fix the link or reject the stub", rel, src)
			}
			rel = src
			id, _ := doc.Scalar("id")
			reason += "; linked by " + id
		}
		out = append(out, rel+"\t"+reason)
	}
	sort.Strings(out)
	return out, nil
}

// relPath is jig_relpath: path relative to the project root.
func relPath(p Project, path string) string {
	return strings.TrimPrefix(path, strings.TrimSuffix(p.Root, "/")+"/")
}

// docReason is _ctx_doc_reason_v: "paths: <glob>" or "domains: <domain>" for the
// first entry of the document that matches, paths before domains.
func docReason(doc *storage.Doc, files, domains []string) (string, bool) {
	if len(files) > 0 {
		items, _ := doc.List("paths")
		for _, item := range items {
			if item != "" && pathMatchesAny(item, files) {
				return "paths: " + item, true
			}
		}
	}
	if len(domains) > 0 {
		items, _ := doc.List("domains")
		for _, item := range items {
			if item == "" {
				continue
			}
			for _, want := range domains {
				if item == want {
					return "domains: " + item, true
				}
			}
		}
	}
	return "", false
}
