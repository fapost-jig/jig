package storage

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// answer is what bash says about one key of one file: _cfg_read_v's value and
// cfg_list_lines on it.
type answer struct {
	found bool
	raw   string
	list  []string
}

// bashConfig asks bash for each (file, key), in one bash process. The list is
// the pipeline of cfg_list_lines (scripts/lib/config.sh), copied here because
// that function reads the value through the project's layered `cfg`, which needs
// a whole project; what it does to the value is what is compared.
func bashConfig(t *testing.T, queries [][2]string) []answer {
	t.Helper()
	var in strings.Builder
	for _, q := range queries {
		in.WriteString(q[0] + "\t" + q[1] + "\n")
	}
	out := runBash(t, `
list_lines() {
  local raw=$1
  [ -n "$raw" ] || return 0
  case "$raw" in
    \[*\]) raw=$(printf '%s' "$raw" | sed 's/^\[//; s/\]$//') ;;
  esac
  printf '%s\n' "$raw" | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/' \
    | sed '/^$/d'
}
while IFS=$'\t' read -r f k; do
  if _cfg_read_v v "$f" "$k"; then printf 'F\t%s\n' "$v"; else printf 'N\t\n'; fi
  printf 'L\t%s\n' "$(list_lines "$v" | tr '\n' '\037')"
done
`, nil, in.String())
	lines := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	if len(lines) != 2*len(queries) {
		t.Fatalf("bash answered %d lines for %d queries:\n%s", len(lines), len(queries), out)
	}
	answers := make([]answer, len(queries))
	for i := range queries {
		l, li := lines[2*i], strings.TrimSuffix(strings.TrimPrefix(lines[2*i+1], "L\t"), "\x1f")
		list := []string{}
		if li != "" {
			list = strings.Split(li, "\x1f")
		}
		answers[i] = answer{found: strings.HasPrefix(l, "F\t"), raw: strings.TrimPrefix(strings.TrimPrefix(l, "F\t"), "N\t"), list: list}
	}
	return answers
}

// compareWithBash fails for every key, of the given files, on which Cfg and bash
// differ — including a key only one of them sees. It returns how many it compared.
func compareWithBash(t *testing.T, files []string, name func(string) string) int {
	t.Helper()
	cfgs := map[string]*Cfg{}
	var queries [][2]string
	bk := bashKeys(t, "cfg", files)
	for _, f := range files {
		c, err := ReadCfgFile(f)
		if err != nil {
			t.Fatal(err)
		}
		cfgs[f] = c
		if !reflect.DeepEqual(c.Keys(), append([]string{}, bk[f]...)) {
			t.Errorf("%s: keys differ\n go:   %q\n bash: %q", name(f), c.Keys(), bk[f])
		}
		for _, k := range union(bk[f], c.Keys()) {
			queries = append(queries, [2]string{f, k})
		}
	}
	for i, a := range bashConfig(t, queries) {
		f, k := queries[i][0], queries[i][1]
		v, found := cfgs[f].Get(k)
		if found != a.found || v != a.raw {
			t.Errorf("%s %s: Go reads %q (found %v), bash %q (found %v)", name(f), k, v, found, a.raw, a.found)
		}
		if l := cfgs[f].List(k); !reflect.DeepEqual(l, a.list) {
			t.Errorf("%s %s: list: Go %q, bash %q", name(f), k, l, a.list)
		}
	}
	return len(queries)
}

// The fixtures of testdata/yaml are the cases where YAML and bash part ways (a
// value starting with { * & !, a # inside quotes, a tab, CRLF, a duplicate key,
// a block list, a document that is not YAML at all). For config and profile
// files there is no such difference: the reader is bash's, line by line.
func TestCfgReadsTheEdgeCaseFixturesAsBashDoes(t *testing.T) {
	needBash(t)
	files, err := filepath.Glob(filepath.Join("testdata", "yaml", "*.yaml"))
	if err != nil || len(files) < 10 {
		t.Fatalf("fixtures: %v", err)
	}
	for i, f := range files {
		abs, err := filepath.Abs(f)
		if err != nil {
			t.Fatal(err)
		}
		files[i] = abs
	}
	n := compareWithBash(t, files, filepath.Base)
	if n < 30 {
		t.Errorf("only %d keys compared", n)
	}
}

func TestCfgValues(t *testing.T) {
	read := func(name string) *Cfg {
		c, err := ReadCfgFile(filepath.Join("testdata", "yaml", name))
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	for _, tc := range []struct{ file, key, want string }{
		{"duplicate-key.yaml", "a", "first"},
		{"hash.yaml", "a", `"x`},  // cut at the first #, quoted or not
		{"hash.yaml", "c", `"x"`}, // quotes stay
		{"hash.yaml", "d", "it"},
		{"flow-mapping.yaml", "a", "{b: c}"},
		{"alias.yaml", "alias", "*x"},
		{"alias.yaml", "base", "&x value"},
		{"tag.yaml", "a", "!!str 12"},
		{"tab.yaml", "a", "b"},
		{"tab.yaml", "c", "x\ty"},
		{"crlf.yaml", "a", "1"},
		{"multiline.yaml", "a", "foo"},
		{"quotes.yaml", "a", "'single quoted'"},
	} {
		got, ok := read(tc.file).Get(tc.key)
		if !ok || got != tc.want {
			t.Errorf("%s %s = %q, %v; want %q", tc.file, tc.key, got, ok, tc.want)
		}
	}
	if _, ok := read("top-list.yaml").Get("a"); ok {
		t.Error("a key in a file with none")
	}
	// A key is a pattern, as in bash: `.` stands for any character.
	c := ParseCfg("git.base_branch: main\ngitXbase_branch: other\n")
	if v, _ := c.Get("git.base_branch"); v != "main" {
		t.Errorf("first line wins: %q", v)
	}
	if v, ok := ParseCfg("gitXbase: v\n").Get("git.base"); !ok || v != "v" {
		t.Errorf("dot in a key: %q, %v", v, ok)
	}
	if _, ok := ParseCfg("git.base: v\n").Get("gitXbase"); ok {
		t.Error("a key matched a line it is not a pattern for")
	}
	if _, ok := ParseCfg("a: v\n").Get("(unbalanced"); ok {
		t.Error("an invalid pattern matched")
	}
}

func TestCfgLists(t *testing.T) {
	c := ParseCfg("p: [generic, shell]\nq: [ \"a b\" , c,, d ]\nr:\ns: single\nt: a,b\nu: []\n")
	for key, want := range map[string][]string{
		"p": {"generic", "shell"}, "q": {"a b", "c", "d"}, "r": {}, "s": {"single"}, "t": {"a", "b"}, "u": {}, "absent": {},
	} {
		if got := c.List(key); !reflect.DeepEqual(got, want) {
			t.Errorf("List(%s) = %q, want %q", key, got, want)
		}
	}
}

func TestCfgKeyPatternAgainstBash(t *testing.T) {
	needBash(t)
	f := filepath.Join(t.TempDir(), "c.yaml")
	if err := os.WriteFile(f, []byte("gitXbase: v\ngit.base: w\na: 1  # c\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if n := compareWithBash(t, []string{f}, func(string) string { return "c.yaml" }); n < 3 {
		t.Errorf("%d keys", n)
	}
	// Keys no line has, asked of both.
	c, _ := ReadCfgFile(f)
	answers := bashConfig(t, [][2]string{{f, "git.base"}, {f, "gitXbase"}, {f, "nope"}, {f, "a"}})
	for i, k := range []string{"git.base", "gitXbase", "nope", "a"} {
		if v, ok := c.Get(k); v != answers[i].raw || ok != answers[i].found {
			t.Errorf("%s: Go %q %v, bash %q %v", k, v, ok, answers[i].raw, answers[i].found)
		}
	}
}
