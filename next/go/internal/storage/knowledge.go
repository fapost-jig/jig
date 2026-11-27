package storage

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// globalDocs are the three documents directly under .ai/knowledge that carry no
// frontmatter by design (jig_knowledge_is_global).
var globalDocs = []string{"GLOSSARY.md", "ARCHITECTURE.md", "RULES.md"}

// GlobalDocs are their names, in the order they are reported.
func GlobalDocs() []string { return append([]string(nil), globalDocs...) }

// KnowledgeDocs is jig_knowledge_docs: every `*.md` regular file under
// .ai/knowledge, absolute paths sorted bytewise, without the three global
// documents. A symbolic link is not followed.
func KnowledgeDocs(root string) []string {
	dir := filepath.Join(root, AiDir, "knowledge")
	if !isDir(dir) {
		return nil
	}
	var docs []string
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || !d.Type().IsRegular() || !strings.HasSuffix(d.Name(), ".md") {
			return nil
		}
		if filepath.Dir(path) == dir {
			for _, g := range globalDocs {
				if d.Name() == g {
					return nil
				}
			}
		}
		docs = append(docs, path)
		return nil
	})
	sort.Strings(docs)
	return docs
}

// ReadKnowledgeDoc reads a document's frontmatter as `fm_read_v` and the YAML
// reader give it: ok is false for a file that is not there, has none or leaves
// it unclosed (the document is skipped); a frontmatter that is not valid YAML
// is a document with no fields.
func ReadKnowledgeDoc(path string) (doc *Doc, ok bool) {
	d, has, err := ReadFrontmatter(path)
	if err != nil {
		if !has {
			return nil, false
		}
		empty, _ := ParseFlatYAML(nil)
		return empty, true
	}
	if !has {
		return nil, false
	}
	return d, true
}

// KnowledgeReadPath is jig_knowledge_read_path_v for a stub that links src: ok
// is false when src is not a regular file inside the repository: a path that
// could leave it, a symlink, or a file reached through a symlinked directory.
func KnowledgeReadPath(root, src string) bool {
	if strings.HasPrefix(src, "/") || strings.HasPrefix(src, "../") ||
		strings.Contains(src, "/../") || strings.HasSuffix(src, "..") {
		return false
	}
	full := filepath.Join(root, filepath.FromSlash(src))
	if !isFile(full) {
		return false
	}
	if info, err := os.Lstat(full); err != nil || info.Mode()&os.ModeSymlink != 0 {
		return false
	}
	parts := strings.Split(src, "/")
	linked := false
	for i := 1; i < len(parts); i++ {
		p := filepath.Join(root, filepath.FromSlash(strings.Join(parts[:i], "/")))
		if info, err := os.Lstat(p); err == nil && info.Mode()&os.ModeSymlink != 0 {
			linked = true
			break
		}
	}
	if !linked {
		return true
	}
	physRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return false
	}
	physDir, err := filepath.EvalSymlinks(filepath.Dir(full))
	if err != nil {
		return false
	}
	return strings.HasPrefix(physDir+"/", strings.TrimSuffix(physRoot, "/")+"/")
}
