package storage

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"

	"go.yaml.in/yaml/v3"
)

// Doc is a flat YAML document: top-level keys whose values are scalars or lists
// of scalars, which is all a knowledge document's frontmatter holds. (Config and
// profile files are not read this way: see Cfg.) It is read at the yaml.Node level so that no scalar is ever typed:
// `yes`, `0.10`, `null`, `2026-01-02` are the strings they were written as
// (YAML's failsafe schema). A value of another shape (a mapping, a list of
// lists) is a key of the document with neither a scalar nor a list value.
//
// Where a key is written twice, the first line wins, as in the bash readers
// (YAML itself calls a duplicate key an error).
type Doc struct {
	keys    []string
	scalars map[string]string
	lists   map[string][]string
	lines   map[string]int
	shaped  map[string]bool // the key holds something that is neither
}

// ParseFlatYAML reads text as a flat YAML document. An empty text is an empty
// document. A text that is not YAML, or whose top level is not a mapping, is an
// error.
func ParseFlatYAML(text []byte) (*Doc, error) {
	d := &Doc{
		scalars: map[string]string{},
		lists:   map[string][]string{},
		lines:   map[string]int{},
		shaped:  map[string]bool{},
	}
	var root yaml.Node
	if err := yaml.Unmarshal(text, &root); err != nil {
		return nil, fmt.Errorf("not valid YAML: %w", err)
	}
	if root.Kind == 0 {
		return d, nil // nothing but blanks and comments
	}
	if root.Kind != yaml.DocumentNode || len(root.Content) != 1 {
		return nil, errors.New("not a YAML document")
	}
	top := resolve(root.Content[0])
	if top.Kind != yaml.MappingNode {
		return nil, errors.New("the top level of the document is not a mapping")
	}
	for i := 0; i+1 < len(top.Content); i += 2 {
		k, v := resolve(top.Content[i]), resolve(top.Content[i+1])
		if k.Kind != yaml.ScalarNode {
			return nil, fmt.Errorf("line %d: a key that is not a scalar", k.Line)
		}
		if _, seen := d.lines[k.Value]; seen {
			continue
		}
		d.keys = append(d.keys, k.Value)
		d.lines[k.Value] = k.Line
		switch v.Kind {
		case yaml.ScalarNode:
			d.scalars[k.Value] = v.Value
		case yaml.SequenceNode:
			items := make([]string, 0, len(v.Content))
			flat := true
			for _, item := range v.Content {
				item = resolve(item)
				if item.Kind != yaml.ScalarNode {
					flat = false
					break
				}
				items = append(items, item.Value)
			}
			if flat {
				d.lists[k.Value] = items
			} else {
				d.shaped[k.Value] = true
			}
		default:
			d.shaped[k.Value] = true
		}
	}
	return d, nil
}

// resolve follows an alias to the node it stands for.
func resolve(n *yaml.Node) *yaml.Node {
	for n.Kind == yaml.AliasNode && n.Alias != nil {
		n = n.Alias
	}
	return n
}

// Keys are the keys of the document in the order they first appear.
func (d *Doc) Keys() []string { return append([]string(nil), d.keys...) }

// Has reports whether the document has the key, whatever its value.
func (d *Doc) Has(key string) bool { _, ok := d.lines[key]; return ok }

// Line is the line a key was first written on, or 0.
func (d *Doc) Line(key string) int { return d.lines[key] }

// Scalar is the value of key when it is a scalar, as the string it was written.
func (d *Doc) Scalar(key string) (string, bool) {
	v, ok := d.scalars[key]
	return v, ok
}

// List is the items of key when it is a list of scalars. An inline `[a, b]` and
// a block list read the same.
func (d *Doc) List(key string) ([]string, bool) {
	v, ok := d.lists[key]
	return append([]string{}, v...), ok
}

// Object is the document as a generic value for schema validation: each key is
// a string or a []any of strings; a key of another shape is a map, so that a
// schema can refuse it.
func (d *Doc) Object() map[string]any {
	out := make(map[string]any, len(d.keys))
	for _, k := range d.keys {
		switch {
		case d.shaped[k]:
			out[k] = map[string]any{}
		default:
			if s, ok := d.scalars[k]; ok {
				out[k] = s
				continue
			}
			items := make([]any, 0, len(d.lists[k]))
			for _, it := range d.lists[k] {
				items = append(items, it)
			}
			out[k] = items
		}
	}
	return out
}

// SplitFrontmatter cuts the frontmatter of a document: the lines strictly
// between a first line `---` and the next line that is exactly `---`, CR at a
// line's end removed (_fm_scan_v). has is false when the first line is not
// `---`; closed is false when nothing closes it, and block then runs to the end.
func SplitFrontmatter(text string) (block string, has, closed bool) {
	lines := splitLines(text)
	if len(lines) == 0 || strings.TrimSuffix(lines[0], "\r") != "---" {
		return "", false, false
	}
	var kept []string
	for _, line := range lines[1:] {
		line = strings.TrimSuffix(line, "\r")
		if line == "---" {
			closed = true
			break
		}
		kept = append(kept, line)
	}
	// Blank lines at the end of the block are not part of it.
	for len(kept) > 0 && kept[len(kept)-1] == "" {
		kept = kept[:len(kept)-1]
	}
	return strings.Join(kept, "\n"), true, closed
}

// ReadFrontmatter reads the frontmatter of the document at path. has is false
// when the file has none (no first line `---`, or nothing closing it); the Doc
// is then nil. A frontmatter that is not valid flat YAML is an error.
func ReadFrontmatter(path string) (doc *Doc, has bool, err error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, false, err
	}
	block, hasBlock, closed := SplitFrontmatter(string(data))
	if !hasBlock || !closed {
		return nil, false, nil
	}
	d, err := ParseFlatYAML([]byte(block))
	if err != nil {
		return nil, true, fmt.Errorf("%s: frontmatter: %w", path, err)
	}
	return d, true, nil
}

// IsNotExist reports whether err says a file is not there.
func IsNotExist(err error) bool { return errors.Is(err, fs.ErrNotExist) }
