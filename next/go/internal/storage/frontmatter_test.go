package storage

import (
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// frontmatterFixture: what Go and bash make of one document of
// testdata/frontmatter. The differences are intended and each says why.
type frontmatterFixture struct {
	file     string
	goHas    bool // Go finds a closed frontmatter
	goErr    bool // and refuses it as YAML
	key      string
	goScalar string
	goList   []string // nil: the key is not a list
	bashGet  string   // fm_get
	bashList []string // fm_list
	bashHas  bool     // fm_has
	why      string
}

var frontmatterFixtures = []frontmatterFixture{
	{file: "colon-in-scalar.md", goHas: true, goErr: true, key: "summary", bashGet: "Terms: a, b", bashHas: true,
		why: "an unquoted `: ` inside a scalar is a nested mapping to YAML, so the frontmatter is refused (schemas/frontmatter.md says the same); bash reads the line"},
	{file: "crlf.md", goHas: true, key: "paths", goList: []string{"a/**", "b"}, bashList: []string{"a/**", "b"}, bashHas: true},
	{file: "unclosed.md", goHas: false, key: "paths", bashList: []string{"a", "b"}, bashHas: false,
		why: "bash reads an unclosed frontmatter up to the end of the file (fm_block); Go says the document has none, as fm_has does"},
	{file: "single-quoted.md", goHas: true, key: "summary", goScalar: "single quoted", bashGet: "'single quoted'", bashHas: true,
		why: "fm_get strips double quotes only; YAML strips single quotes too"},
	{file: "block-lists.md", goHas: true, key: "paths", goList: []string{"a", "b"}, bashList: nil, bashHas: true,
		why: "fm_list takes block items indented by two spaces; YAML also takes `- a` at the indent of its key"},
	{file: "block-lists.md", goHas: true, key: "domains", goList: []string{"d1", "d2"}, bashList: []string{"d1", "d2"}, bashHas: true},
	{file: "hash-in-quotes.md", goHas: true, key: "summary", goScalar: "has # hash", bashGet: `"has`, bashHas: true,
		why: "bash cuts a value at the first #, even inside quotes (schemas/frontmatter.md: a value may not contain #)"},
	{file: "hash-in-quotes.md", goHas: true, key: "requires", goList: []string{"a", "b"}, bashList: []string{"a", "b"}, bashHas: true},
	{file: "none.md", goHas: false, key: "id", bashHas: false},
}

func TestFrontmatterFixturesAsListed(t *testing.T) {
	needBash(t)
	for _, f := range frontmatterFixtures {
		path := filepath.Join("testdata", "frontmatter", f.file)
		doc, has, err := ReadFrontmatter(path)
		if has != f.goHas || (err != nil) != f.goErr {
			t.Errorf("%s: Go has=%v err=%v; the table says has=%v err=%v", f.file, has, err, f.goHas, f.goErr)
			continue
		}
		if has && !f.goErr {
			if f.goList != nil {
				if l, ok := doc.List(f.key); !ok || !reflect.DeepEqual(l, f.goList) {
					t.Errorf("%s %s: list %q, %v; want %q", f.file, f.key, l, ok, f.goList)
				}
			} else if s, ok := doc.Scalar(f.key); f.goScalar != "" && (!ok || s != f.goScalar) {
				t.Errorf("%s %s: scalar %q, %v; want %q", f.file, f.key, s, ok, f.goScalar)
			}
		}
		abs := filepath.Join(repoRoot(t), "next", "go", "internal", "storage", path)
		out := string(runBash(t, `
f=$1; k=$2
if fm_has "$f"; then h=Y; else h=N; fi
fm_block_v blk "$f"
fm_get_block_v g "$blk" "$k"
fm_list_block_v l "$blk" "$k"
printf '%s\n%s\n%s\n' "$h" "$g" "$(printf '%s' "$l" | tr '\n' ',')"
`, nil, "", abs, f.key))
		lines := strings.Split(out, "\n")
		wantList := strings.Join(f.bashList, ",")
		if (lines[0] == "Y") != f.bashHas || lines[1] != f.bashGet || lines[2] != wantList {
			t.Errorf("%s %s: bash has=%s get=%q list=%q; the table says has=%v get=%q list=%q",
				f.file, f.key, lines[0], lines[1], lines[2], f.bashHas, f.bashGet, wantList)
		}
	}
}

func TestEveryFrontmatterFixtureIsInTheTable(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join("testdata", "frontmatter", "*.md"))
	listed := map[string]bool{}
	for _, f := range frontmatterFixtures {
		listed[f.file] = true
	}
	for _, f := range files {
		if !listed[filepath.Base(f)] {
			t.Errorf("%s is not in the table", f)
		}
	}
}
