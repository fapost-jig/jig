package storage

// The invariant of the rewrite: 1.0 writes only what the bash implementation
// reads, and as bash would write it. These tests pin JIG_NOW and put the same
// state file through the Go writers and the bash ones, and read what Go wrote
// with the bash reader.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/clock"
)

const pinnedNow = "1790000000"

// bashBuild builds a state file with the bash writers: `set` is
// _task_state_set_into, `without` is _task_state_without_into. The result is
// printed before bash exits, because bash removes the files it registered for
// cleanup (jig_cleanup_add) when it does.
const bashBuild = `
mode=$1; src=$2; dst=$3; shift 3
case "$mode" in
  set)     _task_state_set_into "$src" "$dst" "$1" "$2" ;;
  without) _task_state_without_into "$src" "$dst" "$@" ;;
esac
cat "$dst"
`

// bashRead asks task_state_get for each key. It prints a value and a newline
// when the key has a line and nothing when it has none, so the record of a key
// is `<key> TAB <what it printed> |`.
const bashRead = `
id=$1; shift
for k in "$@"; do
  out=$(task_state_get "$id" "$k"; printf x)
  printf '%s\t%s|' "$k" "${out%x}"
done
`

func fixtureStates(t *testing.T) map[string]string {
	t.Helper()
	files, err := filepath.Glob(filepath.Join("testdata", "tasks", "*"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no fixtures: %v", err)
	}
	out := map[string]string{}
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		out[filepath.Base(f)] = string(data)
	}
	return out
}

type op struct {
	name  string
	set   [2]string // key, value; used when keys is empty
	keys  []string  // a removal
	isSet bool
}

var ops = []op{
	{name: "set a new key", isSet: true, set: [2]string{"class", "T3"}},
	{name: "replace an existing key", isSet: true, set: [2]string{"status", "ready"}},
	{name: "set a key with a value full of punctuation", isSet: true, set: [2]string{"pr_url", "https://example.com/a/b?c=d&e=f#g \\n 'x' \"y\""}},
	{name: "set an empty value", isSet: true, set: [2]string{"branch", ""}},
	{name: "set updated_at itself", isSet: true, set: [2]string{"updated_at", "2000-01-01"}},
	{name: "set created_at itself", isSet: true, set: [2]string{"created_at", "2000-01-01"}},
	{name: "drop a key", keys: []string{"status"}},
	{name: "drop an absent key", keys: []string{"absent_key"}},
	{name: "drop several keys", keys: []string{"task_id", "class", "created_at"}},
	{name: "drop updated_at", keys: []string{"updated_at"}},
}

func TestGoWritersBuildWhatTheBashWritersBuild(t *testing.T) {
	needBash(t)
	clk, err := clock.New(pinnedNow)
	if err != nil {
		t.Fatal(err)
	}
	env := []string{"JIG_NOW=" + pinnedNow, "JIG_PROJECT=" + t.TempDir()}
	dir := t.TempDir()
	for name, state := range fixtureStates(t) {
		src := filepath.Join(dir, "src-"+name)
		if err := os.WriteFile(src, []byte(state), 0o644); err != nil {
			t.Fatal(err)
		}
		for i, o := range ops {
			dst := filepath.Join(dir, "dst-"+name+"-"+string(rune('a'+i)))
			var want, got string
			if o.isSet {
				want = string(runBash(t, bashBuild, env, "", "set", src, dst, o.set[0], o.set[1]))
				got = StateSet(state, o.set[0], o.set[1], clk.Today())
			} else {
				want = string(runBash(t, bashBuild, env, "", append([]string{"without", src, dst}, o.keys...)...))
				got = StateWithout(state, o.keys, clk.Today())
			}
			if got != want {
				t.Errorf("%s / %s:\n go:   %q\n bash: %q", name, o.name, got, want)
			}
		}
	}
}

func TestBashReadsWhatGoWrote(t *testing.T) {
	needBash(t)
	clk, err := clock.New(pinnedNow)
	if err != nil {
		t.Fatal(err)
	}
	keys := []string{"task_id", "status", "class", "branch", "created_at", "updated_at", "pr_url", "absent_key", "knowledge_consolidated"}
	for name, state := range fixtureStates(t) {
		for _, o := range ops {
			root := projectWithState(t, "t1", state)
			env := []string{"JIG_NOW=" + pinnedNow, "JIG_PROJECT=" + root}
			var err error
			if o.isSet {
				err = TaskStateSet(root, "t1", o.set[0], o.set[1], clk)
			} else {
				err = TaskStateRemove(root, "t1", o.keys, clk)
			}
			if err != nil {
				t.Fatalf("%s / %s: %v", name, o.name, err)
			}
			var want strings.Builder
			for _, k := range keys {
				want.WriteString(k + "\t")
				if v, ok := TaskStateGet(root, "t1", k); ok {
					want.WriteString(v + "\n")
				}
				want.WriteString("|")
			}
			got := string(runBash(t, bashRead, env, "", append([]string{"t1"}, keys...)...))
			if got != want.String() {
				t.Errorf("%s / %s:\n bash reads %q\n go reads   %q", name, o.name, got, want.String())
			}
		}
	}
}
