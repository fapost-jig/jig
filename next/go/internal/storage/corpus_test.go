package storage

// The corpus test: the Go readers against the bash readers, over the files of
// this repository. Bash is the oracle. A file the two read differently is a
// finding, listed below with its reason, never papered over.

import (
	"io/fs"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// knownDifferences are the keys of real knowledge documents that Go and bash
// read differently, keyed "<repo-relative path>|<key>" (a key of "" is the whole
// document). Each stands for a difference that the tables of fixtures explain;
// the corpus test fails for any other. Config and profile files have none: their
// reader is bash's.
var knownDifferences = map[string]string{}

// corpusFiles are the repository's flat YAML files and knowledge documents.
func corpusFiles(t *testing.T, root string) (yamlFiles, docs []string) {
	t.Helper()
	yamlFiles = append(yamlFiles, filepath.Join(root, ".ai", "config.yaml"))
	profiles, err := filepath.Glob(filepath.Join(root, "profiles", "*", "profile.yaml"))
	if err != nil || len(profiles) == 0 {
		t.Fatalf("no profiles found: %v", err)
	}
	yamlFiles = append(yamlFiles, profiles...)
	err = filepath.WalkDir(filepath.Join(root, ".ai", "knowledge"), func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.HasSuffix(path, ".md") {
			docs = append(docs, path)
		}
		return err
	})
	if err != nil || len(docs) == 0 {
		t.Fatalf("no knowledge documents found: %v", err)
	}
	sort.Strings(docs)
	return yamlFiles, docs
}

func rel(root, path string) string {
	r, err := filepath.Rel(root, path)
	if err != nil {
		return path
	}
	return filepath.ToSlash(r)
}

// bashKeys lists the keys bash sees in each file: the config keys
// (jig_config_unknown's pattern) or fm_keys.
func bashKeys(t *testing.T, kind string, files []string) map[string][]string {
	t.Helper()
	script := `
kind=$1; shift
for f in "$@"; do
  printf 'F\t%s\n' "$f"
  if [ "$kind" = cfg ]; then
    sed -n 's/^\([A-Za-z0-9_.-]*\):.*/\1/p' "$f" | awk '!seen[$0]++' | sed 's/^/K\t/'
  else
    fm_keys "$f" | awk '!seen[$0]++' | sed 's/^/K\t/'
  fi
done
`
	out := runBash(t, script, nil, "", append([]string{kind}, files...)...)
	keys := map[string][]string{}
	cur := ""
	for _, line := range strings.Split(strings.TrimSuffix(string(out), "\n"), "\n") {
		switch {
		case strings.HasPrefix(line, "F\t"):
			cur = line[2:]
			keys[cur] = nil
		case strings.HasPrefix(line, "K\t"):
			keys[cur] = append(keys[cur], line[2:])
		}
	}
	return keys
}

func union(a, b []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, k := range append(append([]string{}, a...), b...) {
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	return out
}

func TestConfigAndProfileReadersEqualBash(t *testing.T) {
	needBash(t)
	root := repoRoot(t)
	files, _ := corpusFiles(t, root)
	n := compareWithBash(t, files, func(f string) string { return rel(root, f) })
	if n < 100 {
		t.Errorf("only %d keys compared", n)
	}
}

func TestFrontmatterReadersAgreeWithBash(t *testing.T) {
	needBash(t)
	root := repoRoot(t)
	_, docs := corpusFiles(t, root)

	// Which documents have frontmatter at all, by bash's reading.
	hasOut := runBash(t, `for f in "$@"; do if fm_has "$f"; then printf 'Y\n'; else printf 'N\n'; fi; done`, nil, "", docs...)
	bashHas := strings.Split(strings.TrimSuffix(string(hasOut), "\n"), "\n")
	if len(bashHas) != len(docs) {
		t.Fatalf("bash answered %d of %d", len(bashHas), len(docs))
	}

	var withFM []string
	goDocs := map[string]*Doc{}
	for i, f := range docs {
		d, has, err := ReadFrontmatter(f)
		if (bashHas[i] == "Y") != has {
			t.Errorf("%s: bash fm_has = %s, Go has = %v", rel(root, f), bashHas[i], has)
		}
		if err != nil {
			if knownDifferences[rel(root, f)+"|"] == "" {
				t.Errorf("%s: Go refuses a frontmatter bash reads: %v", rel(root, f), err)
			}
			continue
		}
		if has {
			withFM = append(withFM, f)
			goDocs[f] = d
		}
	}
	if len(withFM) < 20 {
		t.Fatalf("only %d documents with frontmatter", len(withFM))
	}
	bk := bashKeys(t, "fm", withFM)

	var in strings.Builder
	var queries [][2]string
	for _, f := range withFM {
		for _, k := range union(bk[f], goDocs[f].Keys()) {
			queries = append(queries, [2]string{f, k})
			in.WriteString(f + "\t" + k + "\n")
		}
	}
	out := runBash(t, `
last=""
while IFS=$'\t' read -r f k; do
  if [ "$f" != "$last" ]; then fm_block_v blk "$f"; last=$f; fi
  fm_get_block_v g "$blk" "$k"
  fm_list_block_v l "$blk" "$k"
  printf 'G\t%s\n' "$g"
  printf 'L\t%s\n' "$(printf '%s' "$l" | tr '\n' '\037')"
done
`, nil, in.String())
	if len(queries) < 100 {
		t.Fatalf("only %d keys compared", len(queries))
	}
	lines := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	if len(lines) != 2*len(queries) {
		t.Fatalf("bash answered %d lines for %d queries", len(lines), len(queries))
	}
	for i, q := range queries {
		f, k := q[0], q[1]
		g := strings.TrimPrefix(lines[2*i], "G\t")
		l := strings.TrimPrefix(lines[2*i+1], "L\t")
		var bl []string
		if l != "" {
			bl = strings.Split(l, "\x1f")
		}
		d := goDocs[f]
		id := rel(root, f) + "|" + k
		diff := ""
		sc, isScalar := d.Scalar(k)
		li, isList := d.List(k)
		switch {
		case !d.Has(k):
			diff = "bash reads the key, Go does not"
		case isScalar:
			if g != sc {
				diff = "scalar: Go " + sc + ", bash " + g
			}
		case isList:
			if !equalStrings(append([]string{}, bl...), li) {
				diff = "list: Go " + strings.Join(li, "|") + ", bash " + strings.Join(bl, "|")
			}
		default:
			diff = "Go reads neither a scalar nor a list; bash scalar " + g + ", list " + l
		}
		if diff != "" && knownDifferences[id] == "" {
			t.Errorf("%s: %s", id, diff)
		}
	}
}

func TestEveryKnowledgeDocumentFitsTheFrontmatterSchema(t *testing.T) {
	root := repoRoot(t)
	_, docs := corpusFiles(t, root)
	n := 0
	for _, f := range docs {
		if _, has, err := LoadFrontmatter(f); err != nil {
			t.Errorf("%s: %v", rel(root, f), err)
		} else if has {
			n++
		}
	}
	if n < 20 {
		t.Errorf("only %d documents with frontmatter", n)
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
