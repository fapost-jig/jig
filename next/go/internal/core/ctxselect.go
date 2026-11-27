package core

import (
	"sort"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/errs"
	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// ctxSel is the selectors the progressive commands share (CTX_*).
type ctxSel struct {
	task      string
	taskNamed bool
	noTask    bool
	stage     string
	files     string // the file list as text, as CTX_FILES holds it
	domains   string // as CTX_DOMAINS holds it: words, the commas turned into blanks
	topics    string
	ids       string
	catalog   bool
	all       bool
}

func (s *ctxSel) fileLines() []string { return splitFileList(s.files) }

// validStage is jig_valid_stage.
func validStage(s string) bool {
	switch s {
	case "analyze", "discover", "specify", "alternatives", "design", "plan", "implement", "review", "architecture-review", "verify", "consolidate":
		return true
	}
	return false
}

// parseSelectors is _ctx_parse_selectors. Anything the caller must show before
// it dies goes to out.
func parseSelectors(ctx Ctx, p Project, args []string, out *Output) (*ctxSel, error) {
	s := &ctxSel{}
	filesStdin := false
	var filesArg, domainsArg string
	for i := 0; i < len(args); {
		a := args[i]
		value := func() (string, error) {
			if len(args)-i < 2 {
				return "", errs.New(errs.Failed, "context: %s requires a value", a)
			}
			return args[i+1], nil
		}
		switch a {
		case "--no-task":
			s.noTask = true
			i++
		case "--catalog":
			s.catalog = true
			i++
		case "--all":
			s.all = true
			i++
		case "--task", "--stage", "--files", "--domains", "--topics", "--ids":
			v, err := value()
			if err != nil {
				return nil, err
			}
			i += 2
			switch a {
			case "--task":
				s.task, s.taskNamed = v, true
			case "--stage":
				if !validStage(v) {
					return nil, errs.New(errs.Failed, "context: invalid stage: %s", v)
				}
				s.stage = v
			case "--files":
				if v == "-" {
					filesStdin = true
				} else {
					filesArg = v
				}
			case "--domains":
				domainsArg = v
			case "--topics":
				s.topics = strings.ReplaceAll(v, ",", " ")
			case "--ids":
				s.ids = strings.ReplaceAll(v, ",", " ")
			}
		default:
			return nil, errs.New(errs.Failed, "context: unknown argument: %s", a)
		}
	}

	if s.noTask && s.task != "" {
		return nil, errs.New(errs.Failed, "context: --task conflicts with --no-task")
	}
	for _, g := range storage.GlobalDocs() {
		if !storage.IsFile(p.Root + "/.ai/knowledge/" + g) {
			return nil, errs.New(errs.Failed, "context: missing or unreadable mandatory global: .ai/knowledge/%s; restore project knowledge", g)
		}
	}
	if s.task != "" {
		if !storage.ValidID(s.task) {
			return nil, errs.New(errs.Failed, "invalid task id: %s", s.task)
		}
		if !storage.TaskHasState(p.Root, s.task) {
			return nil, errs.New(errs.Failed, "context: unknown task: %s", s.task)
		}
	} else if !s.noTask {
		cur, err := taskCurrent(ctx, p)
		if err != nil {
			return nil, err
		}
		if cur.Status == 2 {
			out.stderr(cur.Stderr)
		}
		s.task = cur.ID
	}

	switch {
	case filesStdin:
		s.files = readAll(ctx.Stdin)
	case filesArg != "":
		s.files = strings.TrimRight(strings.ReplaceAll(filesArg, ",", "\n"), "\n")
	default:
		s.files = strings.Join(touchedFiles(ctx, p.Root, taskBase(p, s.task)), "\n")
	}

	if domainsArg != "" {
		s.domains = strings.ReplaceAll(domainsArg, ",", " ")
	} else if s.task != "" {
		if d, _ := storage.TaskStateGet(p.Root, s.task, "domains"); d != "" {
			s.domains = strings.ReplaceAll(d, ",", " ")
		}
	}
	return s, nil
}

// kdoc is a document whose frontmatter is read, with its place.
type kdoc struct {
	path string // absolute
	rel  string
	doc  *storage.Doc
}

// activeDocs is _ctx_active_docs: the documents with a frontmatter, not retired
// unless --all.
func activeDocs(p Project, s *ctxSel) []kdoc {
	var docs []kdoc
	for _, path := range storage.KnowledgeDocs(p.Root) {
		doc, ok := storage.ReadKnowledgeDoc(path)
		if !ok {
			continue
		}
		if !s.all {
			if st, _ := doc.Scalar("status"); st != "active" && st != "accepted" {
				continue
			}
		}
		docs = append(docs, kdoc{path, relPath(p, path), doc})
	}
	return docs
}

func wordIn(word, words string) bool {
	for _, w := range strings.Fields(words) {
		if w == word {
			return true
		}
	}
	return false
}

func listHas(doc *storage.Doc, key, line string) bool {
	items, _ := doc.List(key)
	for _, it := range items {
		if it == line {
			return true
		}
	}
	return false
}

// globMatch is the first item of the document's list `key` that matches one of
// the files.
func globMatch(doc *storage.Doc, key string, files []string) (string, bool) {
	items, _ := doc.List(key)
	for _, g := range items {
		if g != "" && pathMatchesAny(g, files) {
			return g, true
		}
	}
	return "", false
}

// tagMatch is the first item of the document's list `key` among the words.
func tagMatch(doc *storage.Doc, key, words string) (string, bool) {
	if words == "" {
		return "", false
	}
	items, _ := doc.List(key)
	for _, d := range items {
		if d != "" && wordIn(d, words) {
			return d, true
		}
	}
	return "", false
}

// selectReason is _ctx_select_reason: why this document's body is required.
func selectReason(doc *storage.Doc, s *ctxSel) (string, bool) {
	load, _ := doc.Scalar("load")
	if load == "" {
		load = "matched"
	}
	files := s.fileLines()
	switch load {
	case "stage":
		if s.stage != "" && listHas(doc, "stages", s.stage) {
			return "load: stage; stage: " + s.stage, true
		}
		return "", false
	case "always":
		return "load: always", true
	case "domain":
		if d, ok := tagMatch(doc, "domains", s.domains); ok {
			return "domains: " + d, true
		}
		if s.files != "" {
			if g, ok := globMatch(doc, "paths", files); ok {
				return "paths: " + g, true
			}
		}
		return "", false
	}
	if s.files != "" {
		if g, ok := globMatch(doc, "paths", files); ok {
			return "paths: " + g, true
		}
	}
	if t, ok := tagMatch(doc, "topics", s.topics); ok {
		return "topics: " + t, true
	}
	if s.stage != "" && s.domains != "" && load == "matched" && listHas(doc, "stages", s.stage) {
		if d, ok := tagMatch(doc, "domains", s.domains); ok {
			return "stage: " + s.stage + "; domain: " + d, true
		}
	}
	return "", false
}

// ctxRow is a row of the required set: a document and why it is required.
type ctxRow struct{ rel, reason string }

func rowListed(rows []ctxRow, rel string) bool {
	for _, r := range rows {
		if r.rel == rel {
			return true
		}
	}
	return false
}

// requiredRows is _ctx_required_rows: every required document, sorted, from the
// cache when the fingerprint still matches.
func requiredRows(ctx Ctx, p Project, s *ctxSel) ([]ctxRow, error) {
	h := newHasher(ctx, p)
	if s.task != "" {
		if rows, ok := cacheRead(h, p, s); ok {
			return rows, checkSelectedSources(p, rows)
		}
	}
	docs := activeDocs(p, s)
	var rows []ctxRow
	for _, d := range docs {
		if reason, ok := selectReason(d.doc, s); ok {
			rows = append(rows, ctxRow{d.rel, reason})
		}
	}

	idmap := map[string]kdoc{}
	for _, d := range docs {
		if id, _ := d.doc.Scalar("id"); id != "" {
			if _, dup := idmap[id]; !dup {
				idmap[id] = d
			}
		}
	}
	for _, id := range strings.Fields(s.ids) {
		d, ok := idmap[id]
		if !ok {
			return nil, errs.New(errs.Failed, "context: no active document with id: %s", id)
		}
		if !rowListed(rows, d.rel) {
			rows = append(rows, ctxRow{d.rel, "id: " + id})
		}
	}
	rows, err := closeRequires(p, rows, idmap)
	if err != nil {
		return nil, err
	}
	sortRows(rows)
	if err := checkSelectedSources(p, rows); err != nil {
		return nil, err
	}
	if s.task != "" {
		cacheWrite(ctx, h, p, s, rows)
	}
	return rows, nil
}

// sortRows is `sort` of the lines "<rel><TAB><reason>".
func sortRows(rows []ctxRow) {
	sort.SliceStable(rows, func(a, b int) bool {
		return rows[a].rel+"\t"+rows[a].reason < rows[b].rel+"\t"+rows[b].reason
	})
}

// closeRequires is _ctx_close_requires: the transitive `requires` closure, in
// place.
func closeRequires(p Project, rows []ctxRow, idmap map[string]kdoc) ([]ctxRow, error) {
	for added := true; added; {
		added = false
		snapshot := append([]ctxRow(nil), rows...)
		for _, r := range snapshot {
			if r.rel == "" {
				continue
			}
			doc, ok := storage.ReadKnowledgeDoc(p.Root + "/" + r.rel)
			if !ok {
				continue
			}
			id, _ := doc.Scalar("id")
			reqs, _ := doc.List("requires")
			for _, req := range reqs {
				if req == "" {
					continue
				}
				target, ok := idmap[req]
				if !ok {
					return nil, errs.New(errs.Failed, "context: %s requires unknown or inactive document: %s; run: jig knowledge check", r.rel, req)
				}
				if rowListed(rows, target.rel) {
					continue
				}
				rows = append(rows, ctxRow{target.rel, "requires: " + id})
				added = true
			}
		}
	}
	return rows, nil
}

// checkSelectedSources is _ctx_check_selected_sources: a required stub whose
// source is missing is a refusal.
func checkSelectedSources(p Project, rows []ctxRow) error {
	for _, r := range rows {
		if r.rel == "" {
			continue
		}
		if _, err := readPathOf(p, r.rel); err != nil {
			return err
		}
	}
	return nil
}

// readPathOf is _ctx_read_path for the document at project-relative rel: what
// the agent reads for it, or a refusal when it is a stub with a missing source.
func readPathOf(p Project, rel string) (string, error) {
	doc, ok := storage.ReadKnowledgeDoc(p.Root + "/" + rel)
	if !ok {
		return rel, nil
	}
	src, _ := doc.Scalar("source")
	if src == "" {
		return rel, nil
	}
	if !storage.KnowledgeReadPath(p.Root, src) {
		return "", errs.New(errs.Failed, "context: %s is selected but its source %s is missing; fix the link or reject the stub", rel, src)
	}
	return src, nil
}

// readRows is _ctx_read_rows: the required rows as the agent reads them, a
// stub's row naming its source.
func readRows(p Project, rows []ctxRow) []ctxRow {
	var out []ctxRow
	for _, r := range rows {
		if r.rel == "" {
			continue
		}
		doc, ok := storage.ReadKnowledgeDoc(p.Root + "/" + r.rel)
		src := ""
		if ok {
			src, _ = doc.Scalar("source")
		}
		if src != "" {
			id, _ := doc.Scalar("id")
			out = append(out, ctxRow{src, r.reason + "; linked by " + id})
		} else {
			out = append(out, r)
		}
	}
	return out
}

// catalogRows is _ctx_catalog_rows: "<rel>\t<id>\t<summary>" lines for active
// documents of the entered domains that are not required, plus every
// project-wide one, sorted.
func catalogRows(p Project, s *ctxSel, rows []ctxRow) []string {
	var out []string
	for _, d := range activeDocs(p, s) {
		if rowListed(rows, d.rel) {
			continue
		}
		if load, _ := d.doc.Scalar("load"); load == "stage" {
			continue
		}
		hit := false
		doms, _ := d.doc.List("domains")
		if len(doms) == 0 {
			paths, _ := d.doc.List("paths")
			hit = len(paths) == 0
		} else if s.domains != "" {
			_, hit = tagMatch(d.doc, "domains", s.domains)
		}
		if !hit {
			continue
		}
		id, _ := d.doc.Scalar("id")
		summary, _ := d.doc.Scalar("summary")
		if summary == "" {
			summary = "(no summary)"
		}
		rel := d.rel
		if src, _ := d.doc.Scalar("source"); src != "" {
			if storage.KnowledgeReadPath(p.Root, src) {
				rel = src
			} else {
				summary = "missing source: " + src
			}
		}
		out = append(out, rel+"\t"+id+"\t"+summary)
	}
	sort.Strings(out)
	return out
}
