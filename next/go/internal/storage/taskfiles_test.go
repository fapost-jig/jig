package storage

import (
	"os"
	"path/filepath"
	"testing"
)

func TestIsAbs(t *testing.T) {
	for p, want := range map[string]bool{
		"/a/b": true, `C:/Users/x`: true, `c:\Users\x`: true, "C:/": true,
		"a/b": false, "": false, "C:": false, "C:x": false, "1:/x": false, ".ai/x": false,
	} {
		if got := IsAbs(p); got != want {
			t.Errorf("IsAbs(%q) = %v, want %v", p, got, want)
		}
	}
}

func TestLedgerAndCacheAreKeyedByTaskID(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, ".ai/workspace/tasks/t1")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := LedgerRead(root, "t1"); ok || err != nil {
		t.Errorf("no ledger yet: %v %v", ok, err)
	}
	if err := LedgerWrite(root, "t1", "h\tp\n"); err != nil {
		t.Fatal(err)
	}
	if got, ok, _ := LedgerRead(root, "t1"); !ok || got != "h\tp\n" {
		t.Errorf("%q %v", got, ok)
	}
	if !CacheWrite(root, "t1", "c\n") {
		t.Error("cache not written")
	}
	if got, ok := CacheRead(root, "t1"); !ok || got != "c\n" {
		t.Errorf("%q", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "context")); err != nil {
		t.Error("the ledger is not where the shell keeps it")
	}
	if _, _, err := LedgerRead(root, "../x"); err == nil {
		t.Error("a ledger was read for an invalid id")
	}
	if LedgerWrite(root, "a/b", "x") == nil || CacheWrite(root, "..", "x") {
		t.Error("a file was written for an invalid id")
	}
	if err := os.WriteFile(filepath.Join(dir, "task.md"), []byte("goal\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got, ok := TaskDoc(root, "t1", "task.md"); !ok || got != "goal\n" {
		t.Errorf("%q", got)
	}
	if _, ok := TaskDoc(root, "../t1", "task.md"); ok {
		t.Error("a task document of an invalid id")
	}
}

func TestRecordPathsAreBuiltOnlyForValidNames(t *testing.T) {
	if p, err := TakenRecordPath("/c", "T-1", "sess"); err != nil || p != "/c/.ai/runtime/taken/T-1/sess" {
		t.Errorf("%q %v", p, err)
	}
	for _, c := range [][2]string{{"../x", "s"}, {"T-1", "a/b"}, {"", "s"}, {"T-1", ""}, {"T-1", ".."}} {
		if p, err := TakenRecordPath("/c", c[0], c[1]); err == nil || p != "" {
			t.Errorf("taken %v: %q", c, p)
		}
	}
	if p, err := WorkingRecordPath("/r", "T-1"); err != nil || p != "/r/.ai/runtime/working/T-1" {
		t.Errorf("%q %v", p, err)
	}
	for _, n := range []string{"..", "a/b", "", "-x"} {
		if p, err := WorkingRecordPath("/r", n); err == nil || p != "" {
			t.Errorf("working %q: %q", n, p)
		}
	}
	if got := TakenRecordsOf("/nonexistent", "../x"); got != nil {
		t.Errorf("%v", got)
	}
}
