package storage

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

type shape int

const (
	scalar shape = iota
	list
	other // a key the document has, with neither a scalar nor a list value
	invalid
)

// fixture is one key of one file under testdata/yaml: what the YAML reader (the
// one knowledge frontmatter goes through) makes of it, and, where bash's line
// readers (fm_get, and _cfg_read_v for the files that are not frontmatter) read
// it otherwise, why. Config and profile files never go through YAML (cfg_test.go
// reads these same files with the line reader, which must equal bash).
type fixture struct {
	file, key string
	shape     shape
	scalar    string
	list      []string
	why       string // empty when the two agree
}

var fixtures = []fixture{
	{file: "duplicate-key.yaml", key: "a", shape: scalar, scalar: "first"},
	{file: "hash.yaml", key: "a", shape: scalar, scalar: "x # y",
		why: "bash cuts a value at the first #, quoted or not; YAML ends a plain value at ` #` and never inside quotes"},
	{file: "hash.yaml", key: "b", shape: scalar, scalar: "x"},
	{file: "hash.yaml", key: "c", shape: scalar, scalar: "x",
		why: "bash keeps the quotes of a value, YAML takes them off"},
	{file: "hash.yaml", key: "d", shape: scalar, scalar: "it#s",
		why: "a # not preceded by a blank is part of a YAML plain scalar; bash cuts there"},
	{file: "flow-mapping.yaml", key: "a", shape: other,
		why: "a value starting with { is a YAML mapping, which is no scalar; bash reads the text"},
	{file: "flow-mapping.yaml", key: "b", shape: other,
		why: "the same for an empty mapping"},
	{file: "alias.yaml", key: "base", shape: scalar, scalar: "value",
		why: "a value starting with & is an anchor in YAML; bash keeps it in the value"},
	{file: "alias.yaml", key: "alias", shape: scalar, scalar: "value",
		why: "a value starting with * is an alias in YAML, read as the anchored value; bash reads the text"},
	{file: "alias-undefined.yaml", key: "a", shape: invalid,
		why: "an alias with no anchor makes the document invalid YAML; bash reads the text"},
	{file: "anchor.yaml", key: "a", shape: scalar, scalar: "value",
		why: "an anchor is not part of the value in YAML"},
	{file: "tag.yaml", key: "a", shape: scalar, scalar: "12",
		why: "a value starting with ! is a tag in YAML, which the reader drops; bash keeps it"},
	{file: "tag.yaml", key: "b", shape: scalar, scalar: "thing",
		why: "an unknown tag is dropped from the value too"},
	{file: "tab.yaml", key: "a", shape: scalar, scalar: "b"},
	{file: "tab.yaml", key: "c", shape: scalar, scalar: "x\ty"},
	{file: "typed.yaml", key: "yes", shape: scalar, scalar: "yes"},
	{file: "typed.yaml", key: "n", shape: scalar, scalar: "0.10"},
	{file: "typed.yaml", key: "z", shape: scalar, scalar: "null"},
	{file: "typed.yaml", key: "t", shape: scalar, scalar: "~"},
	{file: "typed.yaml", key: "d", shape: scalar, scalar: "2026-01-02"},
	{file: "typed.yaml", key: "h", shape: scalar, scalar: "0x1F"},
	{file: "typed.yaml", key: "e", shape: scalar, scalar: ""},
	{file: "typed.yaml", key: "q", shape: scalar, scalar: "007",
		why: "bash keeps the quotes of a value, YAML takes them off"},
	{file: "multiline.yaml", key: "a", shape: scalar, scalar: "foo bar",
		why: "a YAML plain scalar goes on over the lines that are indented more; bash reads one line"},
	{file: "lists.yaml", key: "p", shape: list, list: []string{"generic", "shell"}},
	{file: "lists.yaml", key: "q", shape: list, list: []string{"a b", "c", "d"}},
	{file: "lists.yaml", key: "r", shape: list, list: []string{"x", "y z"},
		why: "bash reads inline lists only (config.yaml: `inline lists only`); a block list is an empty value to it"},
	{file: "lists.yaml", key: "s", shape: list, list: []string{}},
	{file: "quotes.yaml", key: "a", shape: scalar, scalar: "single quoted",
		why: "bash keeps the quotes of a value, YAML takes them off"},
	{file: "quotes.yaml", key: "b", shape: scalar, scalar: `double " escaped`,
		why: "bash keeps the quotes and the escape; YAML decodes it"},
	{file: "nested-list.yaml", key: "a", shape: other,
		why: "a list of lists is no flat list"},
	{file: "invalid.yaml", key: "a", shape: invalid,
		why: "a line that is no `key: value` makes the document invalid YAML; bash reads the lines that are"},
	{file: "top-list.yaml", key: "a", shape: invalid,
		why: "a document that is not a mapping is refused"},
	{file: "empty-list-item.yaml", key: "a", shape: invalid,
		why: "an empty item is invalid YAML; bash drops empty items of a list"},
	{file: "crlf.yaml", key: "a", shape: scalar, scalar: "1"},
	{file: "crlf.yaml", key: "b", shape: scalar, scalar: "two"},
}

func readYAMLFixture(name string) (*Doc, error) {
	data, err := os.ReadFile(filepath.Join("testdata", "yaml", name))
	if err != nil {
		return nil, err
	}
	return ParseFlatYAML(data)
}

func TestFlatYAMLReadsFixturesAsListed(t *testing.T) {
	for _, f := range fixtures {
		doc, err := readYAMLFixture(f.file)
		if f.shape == invalid {
			if err == nil {
				t.Errorf("%s: want an error", f.file)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", f.file, err)
			continue
		}
		s, isScalar := doc.Scalar(f.key)
		l, isList := doc.List(f.key)
		switch f.shape {
		case scalar:
			if !isScalar || s != f.scalar {
				t.Errorf("%s %s: scalar = %q, %v; want %q", f.file, f.key, s, isScalar, f.scalar)
			}
		case list:
			if !isList || !reflect.DeepEqual(l, f.list) {
				t.Errorf("%s %s: list = %q, %v; want %q", f.file, f.key, l, isList, f.list)
			}
		case other:
			if isScalar || isList || !doc.Has(f.key) {
				t.Errorf("%s %s: want a key with neither a scalar nor a list", f.file, f.key)
			}
		}
	}
}

func TestEveryFixtureFileIsInTheTable(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join("testdata", "yaml", "*.yaml"))
	listed := map[string]bool{}
	for _, f := range fixtures {
		listed[f.file] = true
	}
	for _, f := range files {
		if !listed[filepath.Base(f)] {
			t.Errorf("%s is in testdata but not in the table of differences", f)
		}
	}
	for _, f := range fixtures {
		if f.why == "" {
			continue
		}
		if len(f.why) < 20 {
			t.Errorf("%s %s: the reason is too short to be one", f.file, f.key)
		}
	}
}

func TestParseFlatYAMLEmpty(t *testing.T) {
	for _, text := range []string{"", "\n\n", "# only a comment\n"} {
		d, err := ParseFlatYAML([]byte(text))
		if err != nil || len(d.Keys()) != 0 {
			t.Errorf("%q: %v, %v", text, d, err)
		}
	}
}

func TestObjectIsWhatTheSchemaReads(t *testing.T) {
	d, err := ParseFlatYAML([]byte("a: x\nb: [y, z]\nc: {k: v}\n"))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"a": "x", "b": []any{"y", "z"}, "c": map[string]any{}}
	if !reflect.DeepEqual(d.Object(), want) {
		t.Errorf("%#v", d.Object())
	}
	if !reflect.DeepEqual(d.Keys(), []string{"a", "b", "c"}) || d.Line("b") != 2 {
		t.Errorf("keys %v, line %d", d.Keys(), d.Line("b"))
	}
}
