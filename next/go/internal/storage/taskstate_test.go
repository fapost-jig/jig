package storage

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/clock"
	"github.com/fapost-jig/jig/next/go/internal/errs"
)

func TestValidID(t *testing.T) {
	for _, ok := range []string{"a", "go-skeleton", "T1.2_x", "9", "a..b"} {
		if !ValidID(ok) {
			t.Errorf("ValidID(%q) = false", ok)
		}
	}
	for _, bad := range []string{"", ".", "..", ".hidden", "-x", "--help", "a/b", "a b", "a:b", "é", "a\nb"} {
		if ValidID(bad) {
			t.Errorf("ValidID(%q) = true", bad)
		}
	}
}

func TestStateGetFollowsTheBashRule(t *testing.T) {
	text := "task_id: t\nstatus:   active  \nstatus: ready\nclass:\nnote without colon\nurl: http://x:1/y\nkey:\tz\n"
	for key, want := range map[string]string{
		"task_id": "t",
		"status":  "active  ", // leading blanks go, trailing ones stay
		"class":   "",
		"url":     "http://x:1/y",
		"key":     "z",
	} {
		got, ok := StateGet(text, key)
		if !ok || got != want {
			t.Errorf("StateGet(%q) = %q, %v; want %q", key, got, ok, want)
		}
	}
	if _, ok := StateGet(text, "absent"); ok {
		t.Error("absent key found")
	}
	if _, ok := StateGet(text, "stat"); ok {
		t.Error("a prefix of a key is not the key")
	}
	if _, ok := StateGet("", "a"); ok {
		t.Error("empty text has no keys")
	}
	// The last line needs no newline.
	if got, ok := StateGet("a: 1", "a"); !ok || got != "1" {
		t.Errorf("last line: %q, %v", got, ok)
	}
}

func TestStateKeysTakesTheFirstLineOfAKey(t *testing.T) {
	keys, values := StateKeys("a: 1\nb: 2\na: 3\nno colon\n")
	if strings.Join(keys, ",") != "a,b" || values["a"] != "1" || values["b"] != "2" {
		t.Errorf("%v %v", keys, values)
	}
}

func TestStateSetAndWithout(t *testing.T) {
	src := "task_id: t\nstatus: active\ncreated_at: 2026-11-01\nupdated_at: 2026-11-02\n"
	cases := []struct{ name, got, want string }{
		{"new key goes before created_at",
			StateSet(src, "class", "T2", "2026-12-01"),
			"task_id: t\nstatus: active\nclass: T2\ncreated_at: 2026-11-01\nupdated_at: 2026-12-01\n"},
		{"existing key is replaced",
			StateSet(src, "status", "ready", "2026-12-01"),
			"task_id: t\nstatus: ready\ncreated_at: 2026-11-01\nupdated_at: 2026-12-01\n"},
		{"without created_at the key goes last",
			StateSet("task_id: t\n", "class", "T0", "2026-12-01"),
			"task_id: t\nclass: T0\n"},
		{"an empty file gets the key",
			StateSet("", "k", "v", "2026-12-01"),
			"k: v\n"},
		{"a missing final newline is added",
			StateSet("a: 1", "b", "2", "2026-12-01"),
			"a: 1\nb: 2\n"},
		{"every line of a key is replaced",
			StateSet("k: 1\nx: y\nk: 2\n", "k", "9", "2026-12-01"),
			"k: 9\nx: y\nk: 9\n"},
		{"remove drops every line of the key and refreshes updated_at",
			StateWithout(src, []string{"status"}, "2026-12-01"),
			"task_id: t\ncreated_at: 2026-11-01\nupdated_at: 2026-12-01\n"},
		{"remove of an absent key only refreshes updated_at",
			StateWithout(src, []string{"nope"}, "2026-12-01"),
			"task_id: t\nstatus: active\ncreated_at: 2026-11-01\nupdated_at: 2026-12-01\n"},
		{"remove of several keys",
			StateWithout(src, []string{"task_id", "status"}, "2026-12-01"),
			"created_at: 2026-11-01\nupdated_at: 2026-12-01\n"},
		{"remove of a prefix does not drop the longer key",
			StateWithout("ab: 1\na: 2\n", []string{"a"}, "x"),
			"ab: 1\n"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s:\n got %q\nwant %q", c.name, c.got, c.want)
		}
	}
}

func projectWithState(t *testing.T, id, state string) string {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, ".ai", "workspace", "tasks", id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "state"), []byte(state), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestTaskStateReadWriteOnDisk(t *testing.T) {
	clk, err := clock.New("1790000000")
	if err != nil {
		t.Fatal(err)
	}
	root := projectWithState(t, "t1", "task_id: t1\nstatus: active\ncreated_at: 2026-11-01\nupdated_at: 2026-11-02\n")
	if err := TaskStateSet(root, "t1", "class", "T1", clk); err != nil {
		t.Fatal(err)
	}
	if got, ok := TaskStateGet(root, "t1", "class"); !ok || got != "T1" {
		t.Errorf("class = %q, %v", got, ok)
	}
	if got, _ := TaskStateGet(root, "t1", "updated_at"); got != clk.Today() {
		t.Errorf("updated_at = %q, want %q", got, clk.Today())
	}
	if err := TaskStateRemove(root, "t1", []string{"class"}, clk); err != nil {
		t.Fatal(err)
	}
	if _, ok := TaskStateGet(root, "t1", "class"); ok {
		t.Error("class survived its removal")
	}
	statePath, _ := taskStatePath(root, "t1")
	entries, _ := os.ReadDir(filepath.Dir(statePath))
	if len(entries) != 1 {
		t.Errorf("a temporary file was left behind: %v", entries)
	}
}

func TestTaskStateNeverBuildsAPathFromABadID(t *testing.T) {
	root := projectWithState(t, "ok", "task_id: ok\n")
	if _, ok := TaskStateGet(root, "../ok", "task_id"); ok {
		t.Error("read through a bad id")
	}
	if _, ok := TaskStateGet(root, "missing", "task_id"); ok {
		t.Error("read a task that is not there")
	}
	if err := TaskStateSet(root, "../ok", "k", "v", clock.Real()); !errors.Is(err, ErrInvalidID) {
		t.Errorf("err = %v", err)
	}
	if err := TaskStateSet(root, "missing", "k", "v", clock.Real()); !IsNotExist(err) {
		t.Errorf("err = %v", err)
	}
}

func TestLoadTaskState(t *testing.T) {
	root := projectWithState(t, "good", "task_id: good\nstatus: active\nclass: T2\ncreated_at: 2026-11-01\nupdated_at: 2026-11-02\nfuture: x\n")
	st, err := LoadTaskState(root, "good")
	if err != nil || st.TaskID != "good" || st.Class != "T2" || st.Status != "active" {
		t.Fatalf("%+v, %v", st, err)
	}
	root = projectWithState(t, "bad", "task_id: bad\nstatus: finished\ncreated_at: 2026-11-01\nupdated_at: 2026-11-02\n")
	if _, err := LoadTaskState(root, "bad"); err == nil {
		t.Error("an invalid status was accepted")
	} else if e := err.(*errs.Error); e.Code != errs.Failed {
		t.Errorf("code = %s", e.Code)
	}
	if _, err := LoadTaskState(root, "nope"); err == nil || err.(*errs.Error).Code != errs.NotFound {
		t.Errorf("err = %v", err)
	}
	if _, err := LoadTaskState(root, "-x"); err == nil || err.(*errs.Error).Code != errs.Usage {
		t.Errorf("err = %v", err)
	}
}

func TestLoadFrontmatter(t *testing.T) {
	dir := t.TempDir()
	write := func(name, text string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	fm, has, err := LoadFrontmatter(write("a.md", "---\nid: convention-x\ntype: convention\nstatus: active\npaths: [a/**, b]\ndomains:\n  - d1\n---\n# body\n"))
	if err != nil || !has || fm.ID != "convention-x" || len(fm.Paths) != 2 || len(fm.Domains) != 1 {
		t.Fatalf("%+v, %v, %v", fm, has, err)
	}
	if _, has, err := LoadFrontmatter(write("none.md", "# no frontmatter\n")); has || err != nil {
		t.Errorf("none: %v, %v", has, err)
	}
	if _, _, err := LoadFrontmatter(write("bad.md", "---\nid: x\ntype: essay\nstatus: active\n---\n")); err == nil {
		t.Error("a bad type was accepted")
	}
	if _, _, err := LoadFrontmatter(filepath.Join(dir, "missing.md")); err == nil || err.(*errs.Error).Code != errs.NotFound {
		t.Errorf("missing: %v", err)
	}
}

func TestSplitFrontmatter(t *testing.T) {
	block, has, closed := SplitFrontmatter("---\r\na: 1\r\n\r\nb: 2\r\n\r\n---\r\nbody")
	if !has || !closed || block != "a: 1\n\nb: 2" {
		t.Errorf("%q %v %v", block, has, closed)
	}
	if _, has, _ := SplitFrontmatter("x\n---\n"); has {
		t.Error("frontmatter that does not start on line 1")
	}
	block, has, closed = SplitFrontmatter("---\na: 1\n")
	if !has || closed || block != "a: 1" {
		t.Errorf("unclosed: %q %v %v", block, has, closed)
	}
}

// The path builder itself refuses an id that would leave the tasks directory,
// so no caller can build such a path (RULES.md: validated at the one function
// that builds the path).
func TestTaskStatePathRefusesAnInvalidID(t *testing.T) {
	for _, id := range []string{"", "..", "../../x", "a/b", "-x", ".hidden"} {
		if p, err := taskStatePath(t.TempDir(), id); !errors.Is(err, ErrInvalidID) || p != "" {
			t.Errorf("taskStatePath(%q) = %q, %v; want no path and ErrInvalidID", id, p, err)
		}
	}
}
