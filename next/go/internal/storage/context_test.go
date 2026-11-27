package storage

import (
	"os"
	"path/filepath"
	"testing"
)

func put(t *testing.T, root, rel, text string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestQueuePlaceRankDepsAndFormat(t *testing.T) {
	root := t.TempDir()
	if _, ok := ReadQueuePlace(root, "a"); ok {
		t.Error("no queue file, yet a place")
	}
	put(t, root, ".ai/runtime/queue", "# jig queue 1\n"+
		"item\ttask:a\t-\t10\t3\n"+
		"item\ttask:b\t-\t5\t-\n"+
		"item\ttask:c\tepic:x\t1\t1\n"+
		"dep\ttask:a\ttask:b\twaits for b\n"+
		"junk\n")
	pl, ok := ReadQueuePlace(root, "a")
	if !ok || pl.Rank != 2 || pl.Count != 2 || pl.Level != "-" || pl.Priority != "3" || len(pl.Deps) != 1 || pl.Deps[0] != (QueueDep{"task:b", "waits for b"}) {
		t.Errorf("%+v %v", pl, ok)
	}
	if pl, ok := ReadQueuePlace(root, "c"); !ok || pl.Rank != 1 || pl.Count != 1 || pl.Level != "epic:x" {
		t.Errorf("%+v", pl)
	}
	if _, ok := ReadQueuePlace(root, "zz"); ok {
		t.Error("a task that is not queued has a place")
	}
	put(t, root, ".ai/runtime/queue", "# jig queue 2\nitem\ttask:a\t-\t1\t1\n")
	if _, ok := ReadQueuePlace(root, "a"); ok {
		t.Error("a queue of another format version was read")
	}
}

func TestPauseRequestFirstOneCounts(t *testing.T) {
	root := t.TempDir()
	put(t, root, ".ai/runtime/queue", "request\ttask:a\tpause\t2026-01-01T00:00:00Z\twhy\textra\n"+
		"request\ttask:a\tpause\t2026-02-01T00:00:00Z\n"+
		"request\ttask:b\tpause\t2026-03-01T00:00:00Z\n")
	if at, reason, ok := PauseRequest(root, "a"); !ok || at != "2026-01-01T00:00:00Z" || reason != "why" {
		t.Errorf("%q %q %v", at, reason, ok)
	}
	if at, reason, ok := PauseRequest(root, "b"); !ok || at != "2026-03-01T00:00:00Z" || reason != "" {
		t.Errorf("%q %q %v", at, reason, ok)
	}
	if _, _, ok := PauseRequest(root, "c"); ok {
		t.Error("no request, yet one was found")
	}
}

func TestRecordGetAndWrite(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "r")
	if !WriteRecord(f, "a: 1\r\nb: two words\nc: \n") {
		t.Fatal("write failed")
	}
	if v, ok := RecordGet(f, "a"); !ok || v != "1" {
		t.Errorf("a %q %v", v, ok)
	}
	if v, ok := RecordGet(f, "b"); !ok || v != "two words" {
		t.Errorf("b %q %v", v, ok)
	}
	if v, ok := RecordGet(f, "c"); !ok || v != "" {
		t.Errorf("c %q %v", v, ok)
	}
	if _, ok := RecordGet(f, "d"); ok {
		t.Error("absent key found")
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 1 {
		t.Errorf("a temporary file was left behind: %v", entries)
	}
}

func TestKnowledgeDocsWalkSortedWithoutGlobals(t *testing.T) {
	root := t.TempDir()
	for _, f := range []string{"GLOSSARY.md", "RULES.md", "b.md", "a/z.md", "a/RULES.md", "notes.txt", "domains/d/RULES.md"} {
		put(t, root, ".ai/knowledge/"+f, "x")
	}
	var got []string
	for _, d := range KnowledgeDocs(root) {
		rel, _ := filepath.Rel(root, d)
		got = append(got, filepath.ToSlash(rel))
	}
	want := []string{".ai/knowledge/a/RULES.md", ".ai/knowledge/a/z.md", ".ai/knowledge/b.md", ".ai/knowledge/domains/d/RULES.md"}
	if len(got) != len(want) {
		t.Fatalf("%v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("%v, want %v", got, want)
			break
		}
	}
}

func TestKnowledgeReadPathRules(t *testing.T) {
	root := t.TempDir()
	put(t, root, "docs/real.md", "x")
	put(t, root, "outside/secret.md", "x")
	if err := os.Symlink("real.md", filepath.Join(root, "docs/link.md")); err != nil {
		t.Skip("no symlinks")
	}
	if err := os.Symlink(filepath.Join(root, "outside"), filepath.Join(root, "docs/dirlink")); err != nil {
		t.Fatal(err)
	}
	for src, want := range map[string]bool{
		"docs/real.md":           true,
		"docs/link.md":           false, // a symlink
		"docs/missing.md":        false,
		"/etc/passwd":            false,
		"../x.md":                false,
		"docs/../docs/real.md":   false,
		"docs/dirlink/secret.md": true, // a linked directory that leads back inside the repository
	} {
		if got := KnowledgeReadPath(root, src); got != want {
			t.Errorf("%q: %v, want %v", src, got, want)
		}
	}
}
