package storage

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestTaskPathsAreBuiltOnlyForAValidID(t *testing.T) {
	for _, id := range []string{"../x", "a/b", "", ".hidden", "-x", "a b"} {
		if p, err := TaskDirPath("/r", id); err == nil || p != "" {
			t.Errorf("TaskDirPath(%q) = %q, %v", id, p, err)
		}
		if p, err := TaskStatePath("/r", id); err == nil || p != "" {
			t.Errorf("TaskStatePath(%q) = %q, %v", id, p, err)
		}
		if p, err := TaskWorkspaceRel(id); err == nil || p != "" {
			t.Errorf("TaskWorkspaceRel(%q) = %q, %v", id, p, err)
		}
		if TaskHasState("/r", id) || TaskFileExists("/r", id, "task.md") {
			t.Errorf("a file of the invalid id %q was looked for", id)
		}
	}
	if p, err := TaskStatePath("/r", "t-1"); err != nil || p != "/r/.ai/workspace/tasks/t-1/state" {
		t.Errorf("%q %v", p, err)
	}
	if p, _ := TaskWorkspaceRel("t-1"); p != ".ai/workspace/tasks/t-1" {
		t.Errorf("%q", p)
	}
}

func TestSlashWritesTheSeparatorAsASlash(t *testing.T) {
	if got := slashWith(`C:\Users\x\p\.ai\knowledge\a.md`, '\\'); got != "C:/Users/x/p/.ai/knowledge/a.md" {
		t.Errorf("%q", got)
	}
	if got := slashWith("/a/b", '/'); got != "/a/b" {
		t.Errorf("%q", got)
	}
}

func TestQueueCancelIsClaimedAgainstTheRevisionItWasReadAt(t *testing.T) {
	root := t.TempDir()
	queue := filepath.Join(root, ".ai/runtime/queue")
	if err := os.MkdirAll(filepath.Dir(queue), 0o755); err != nil {
		t.Fatal(err)
	}
	body := "# jig queue 1 — x\nitem\ttask:a\t-\t100\t-\nrequest\ttask:a\tpause\t2026-01-01T00:00:00Z\twhy\n"
	if err := os.WriteFile(queue, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := RevisionBump(root, pinnedClock(t)); err != nil {
		t.Fatal(err)
	}
	before := RevisionRead(root)

	// Another write lands between the read of the queue and the claim: nothing is written.
	queueBeforeClaim = func() { _ = RevisionBump(root, pinnedClock(t)) }
	err := QueueCancelRequest(root, "task:a", "pause", pinnedClock(t))
	queueBeforeClaim = func() {}
	if !errors.Is(err, ErrStaleRevision) {
		t.Fatalf("err = %v, want a stale revision", err)
	}
	if got, _ := os.ReadFile(queue); string(got) != body {
		t.Errorf("a stale write changed the queue:\n%s", got)
	}
	if entries, _ := os.ReadDir(filepath.Dir(queue)); len(entries) != 2 { // queue and revision/
		t.Errorf("a temporary file was left: %v", entries)
	}
	if RevisionRead(root) != before+1 {
		t.Errorf("revision %d, want %d", RevisionRead(root), before+1)
	}

	// Read again, it lands, and raises the revision twice (the claim, then the write).
	if err := QueueCancelRequest(root, "task:a", "pause", pinnedClock(t)); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(queue); string(got) != "# jig queue 1 — written by `jig queue` only; do not edit by hand\nitem\ttask:a\t-\t100\t-\n" {
		t.Errorf("queue:\n%s", got)
	}
	if RevisionRead(root) != before+3 {
		t.Errorf("revision %d, want %d", RevisionRead(root), before+3)
	}
	if err := QueueCancelRequest(root, "task:a", "pause", pinnedClock(t)); !errors.Is(err, ErrNoRequest) {
		t.Errorf("a second cancel: %v", err)
	}
}

func TestRevisionClaimRefusesAStaleExpectation(t *testing.T) {
	root := t.TempDir()
	clk := pinnedClock(t)
	if err := RevisionBump(root, clk); err != nil {
		t.Fatal(err)
	}
	cur := RevisionRead(root)
	if err := RevisionClaim(root, cur-1, clk); !errors.Is(err, ErrStaleRevision) {
		t.Errorf("old expectation: %v", err)
	}
	if err := RevisionClaim(root, 0, clk); !errors.Is(err, ErrStaleRevision) {
		t.Errorf("0 with a counter: %v", err)
	}
	if err := RevisionClaim(root, cur, clk); err != nil || RevisionRead(root) != cur+1 {
		t.Errorf("claim: %v %d", err, RevisionRead(root))
	}
}
