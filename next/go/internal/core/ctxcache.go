package core

import (
	"fmt"
	"sort"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/proc"
	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// hasher gives the object name git gives a file (`git hash-object --no-filters
// --stdin-paths`). A repository of the sha1 object format is hashed in this
// process; one of another format is asked of git, with the project's own git
// directory so that a file outside the project hashes in its hash space.
type hasher struct {
	ctx    Ctx
	p      Project
	asked  bool
	sha256 bool
	gitDir string
}

func newHasher(ctx Ctx, p Project) *hasher { return &hasher{ctx: ctx, p: p} }

func (h *hasher) ask() {
	if h.asked {
		return
	}
	h.asked = true
	if r, err := h.ctx.Exec.Git(h.p.Root, "rev-parse", "--show-object-format"); err == nil && r.Code == 0 {
		h.sha256 = strings.TrimSpace(r.Stdout) == "sha256"
	}
	if h.sha256 {
		if r, err := h.ctx.Exec.Git(h.p.Root, "rev-parse", "--absolute-git-dir"); err == nil && r.Code == 0 {
			h.gitDir = strings.TrimRight(r.Stdout, "\n")
		}
	}
}

// list is jig_hash_list: the hashes of names, relative to dir, in order.
func (h *hasher) list(dir string, names []string) ([]string, error) {
	if len(names) == 0 {
		return nil, nil
	}
	h.ask()
	if h.sha256 {
		c := proc.Cmd{Name: "git", Args: []string{"hash-object", "--no-filters", "--stdin-paths"}, Dir: dir, Stdin: strings.Join(names, "\n") + "\n"}
		if h.gitDir != "" {
			c.Env = []string{"GIT_DIR=" + h.gitDir}
		}
		r, err := h.ctx.Exec.Run(c)
		if err != nil || r.Code != 0 {
			return nil, fmt.Errorf("git hash-object failed")
		}
		out := strings.Split(strings.TrimRight(r.Stdout, "\n"), "\n")
		if len(out) != len(names) {
			return nil, fmt.Errorf("git hash-object answered %d of %d", len(out), len(names))
		}
		return out, nil
	}
	hashes := make([]string, 0, len(names))
	for _, n := range names {
		sum, err := storage.HashFileSHA1(dir + "/" + n)
		if err != nil {
			return nil, err
		}
		hashes = append(hashes, sum)
	}
	return hashes, nil
}

// hashedPath is `<hash><TAB><path>`.
type hashedPath struct{ hash, path string }

// hashPaths is _ctx_hash_paths: repository-relative paths are hashed from the
// project root, absolute ones, which are linked documents, by directory.
func (h *hasher) hashPaths(paths []string) ([]hashedPath, error) {
	var rel, abs []string
	for _, x := range paths {
		switch {
		case x == "":
		case x[0] == '/':
			abs = append(abs, x)
		default:
			rel = append(rel, x)
		}
	}
	var out []hashedPath
	hs, err := h.list(h.p.Root, rel)
	if err != nil {
		return nil, err
	}
	for i, x := range rel {
		out = append(out, hashedPath{hs[i], x})
	}
	dirSet := map[string]bool{}
	for _, x := range abs {
		dirSet[x[:strings.LastIndex(x, "/")]] = true
	}
	dirs := make([]string, 0, len(dirSet))
	for d := range dirSet {
		dirs = append(dirs, d)
	}
	sort.Strings(dirs)
	for _, d := range dirs {
		var names []string
		for _, x := range abs {
			if n, ok := strings.CutPrefix(x, d+"/"); ok && !strings.Contains(n, "/") {
				names = append(names, n)
			}
		}
		hs, err := h.list(d, names)
		if err != nil {
			return nil, err
		}
		for i, n := range names {
			out = append(out, hashedPath{hs[i], d + "/" + n})
		}
	}
	return out, nil
}

const cacheMark = "=== rows ==="

func cacheFile(p Project, id string) string {
	return storage.TaskDirPath(p.Root, id) + "/context-cache"
}

// fingerprint is _ctx_cache_fingerprint: every selector the selection reads and
// the content of every knowledge document.
func fingerprint(h *hasher, p Project, s *ctxSel) (string, error) {
	var rels []string
	for _, d := range storage.KnowledgeDocs(p.Root) {
		rels = append(rels, relPath(p, d))
	}
	sort.Strings(rels)
	all := 0
	if s.all {
		all = 1
	}
	var b strings.Builder
	fmt.Fprintf(&b, "rule=domain-or-paths;stage-only\nstage=%s\nfiles=%s\ndomains=%s\ntopics=%s\nids=%s\nall=%d\n",
		s.stage, s.files, s.domains, s.topics, s.ids, all)
	hs, err := h.list(p.Root, rels)
	if err != nil {
		return "", err
	}
	for _, x := range hs {
		b.WriteString(x + "\n")
	}
	return b.String(), nil
}

// cacheRead is _ctx_cache_read: the cached rows, when a cache for these
// selectors exists and its fingerprint still matches the documents on disk.
func cacheRead(h *hasher, p Project, s *ctxSel) ([]ctxRow, bool) {
	text, ok := storage.ReadText(cacheFile(p, s.task))
	if !ok {
		return nil, false
	}
	fp, err := fingerprint(h, p, s)
	if err != nil {
		return nil, false
	}
	lines := strings.Split(text, "\n")
	var cached []string
	i := 0
	for ; i < len(lines); i++ {
		if lines[i] == cacheMark {
			break
		}
		cached = append(cached, lines[i])
	}
	if strings.TrimRight(strings.Join(cached, "\n"), "\n") != strings.TrimRight(fp, "\n") {
		return nil, false
	}
	var rows []ctxRow
	if i < len(lines) {
		for _, l := range splitFileLines(strings.Join(lines[i+1:], "\n")) {
			rel, reason, _ := strings.Cut(l, "\t")
			rows = append(rows, ctxRow{rel, reason})
		}
	}
	return rows, i < len(lines)
}

// splitFileLines is the lines of a text, the last one needing no newline.
func splitFileLines(text string) []string {
	if text == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(text, "\n"), "\n")
}

// cacheWrite is _ctx_cache_write: the rows under the fingerprint that produced
// them, when the task's workspace passes the write check; never an error.
func cacheWrite(ctx Ctx, h *hasher, p Project, s *ctxSel, rows []ctxRow) {
	if guardWrite(ctx, p, s.task, "context") != nil {
		return
	}
	fp, err := fingerprint(h, p, s)
	if err != nil {
		return
	}
	var b strings.Builder
	b.WriteString(fp + cacheMark + "\n")
	for _, r := range rows {
		b.WriteString(r.rel + "\t" + r.reason + "\n")
	}
	storage.WriteFileTmp(cacheFile(p, s.task), b.String())
}
