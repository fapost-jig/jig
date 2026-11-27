package core

import (
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/storage"
)

func ack(t *testing.T, root string, stdin string, args ...string) Output {
	t.Helper()
	ctx, _ := ctxFor(root, "feat", nil, nil)
	if stdin != "" {
		ctx.Stdin = strings.NewReader(stdin)
	}
	return Context(ctx, append([]string{"acknowledge"}, args...))
}

func ackFixture(t *testing.T) string {
	root := progressiveFixture(t)
	knowledgeDoc(t, root, "a.md", "k-a", "active", "paths: [src/**]\n")
	write(t, root, "docs/real.md", "real\n")
	knowledgeDoc(t, root, "stub.md", "k-stub", "active", "source: docs/real.md\n")
	return root
}

func TestAcknowledgeWritesASortedLedger(t *testing.T) {
	root := ackFixture(t)
	out := ack(t, root, "", "--task", "t1", "--stage", "plan", "--files", ".ai/knowledge/a.md,./.ai/knowledge/RULES.md,.ai/knowledge/a.md,docs/real.md")
	if out.Code != 0 || text(out) != "acknowledged 3 document(s) for t1 at plan\n" {
		t.Fatalf("%d %q", out.Code, text(out))
	}
	h := func(s string) string { return storage.BlobSHA1([]byte(s)) }
	lines := []string{
		h("real\n") + "\tdocs/real.md\tplan",
		h("RULES.md\n") + "\t.ai/knowledge/RULES.md\tplan",
		h(read(root, ".ai/knowledge/a.md")) + "\t.ai/knowledge/a.md\tplan",
	}
	if got := read(root, ".ai/workspace/tasks/t1/context"); strings.Count(got, "\n") != 3 {
		t.Fatalf("ledger:\n%s", got)
	}
	got := read(root, ".ai/workspace/tasks/t1/context")
	for _, l := range lines {
		if !strings.Contains(got, l+"\n") {
			t.Errorf("missing %q in\n%s", l, got)
		}
	}
	// Re-acknowledging without a stage replaces the line and keeps the others whole.
	write(t, root, ".ai/workspace/tasks/t1/context", got+"old\t.ai/knowledge/GLOSSARY.md\n")
	out = ack(t, root, ".ai/knowledge/a.md\n\n", "--task", "t1", "--files", "-")
	if text(out) != "acknowledged 1 document(s) for t1\n" {
		t.Errorf("%q", text(out))
	}
	got = read(root, ".ai/workspace/tasks/t1/context")
	if !strings.Contains(got, "old\t.ai/knowledge/GLOSSARY.md\n") || !strings.Contains(got, "\t.ai/knowledge/a.md\t-\n") || strings.Contains(got, "a.md\tplan") {
		t.Errorf("ledger:\n%s", got)
	}
	// Revoke withdraws whatever stage it was made at.
	out = ack(t, root, "", "--task", "t1", "--revoke", "--files", "docs/real.md")
	if text(out) != "revoked 1 document(s) for t1\n" || strings.Contains(read(root, ".ai/workspace/tasks/t1/context"), "docs/real.md") {
		t.Errorf("%q", text(out))
	}
}

func TestAcknowledgeRefusesABatchWholly(t *testing.T) {
	root := ackFixture(t)
	out := ack(t, root, "", "--task", "t1", "--files", ".ai/knowledge/a.md,../x.md,/etc/passwd,notes.txt,.ai/knowledge/missing.md")
	want := "[err] context acknowledge: path may not contain '..': ../x.md\n" +
		"context acknowledge: path must be repository-relative: /etc/passwd (an absolute path only for a document a Linked: line of the task reaches)\n" +
		"context acknowledge: not a knowledge document or a linked source: notes.txt\n" +
		"context acknowledge: no such document: .ai/knowledge/missing.md\n" +
		"[err] jig: error: context acknowledge: 4 path(s) refused; nothing recorded. Give the paths as jig context guard prints them\n"
	if out.Code != 1 || text(out) != want {
		t.Errorf("%d\n%s", out.Code, text(out))
	}
	if read(root, ".ai/workspace/tasks/t1/context") != "" {
		t.Error("a refused batch wrote the ledger")
	}
}

func TestAcknowledgeOptionErrors(t *testing.T) {
	root := ackFixture(t)
	for args, msg := range map[string]string{
		"--files x":             "context acknowledge: --task is required",
		"--task t1":             "context acknowledge: --files is required",
		"--task t1 --files ,":   "context acknowledge: --files is empty",
		"--task nope --files x": "context: unknown task: nope",
		"--task t1 --revoke --stage plan --files x":     "context acknowledge: --revoke takes no --stage: a revoke withdraws the path's acknowledgement whatever stage it was made at",
		"--task t1 --stage bogus --files x":             "context: invalid stage: bogus",
		"--task t1 --bogus":                             "context: unknown argument: --bogus",
		"--task t1 --revoke --files .ai/knowledge/a.md": "", // refused through the batch, below
	} {
		out := ack(t, root, "", strings.Fields(args)...)
		if msg != "" && !strings.HasSuffix(text(out), "jig: error: "+msg+"\n") {
			t.Errorf("%s: %q", args, text(out))
		}
	}
	out := ack(t, root, "", "--task", "t1", "--revoke", "--files", ".ai/knowledge/a.md")
	if !strings.Contains(text(out), "not acknowledged for this task: .ai/knowledge/a.md\n") {
		t.Errorf("%q", text(out))
	}
}

func TestAcknowledgeNormalisesAbsolutePathsInsideTheProject(t *testing.T) {
	root := ackFixture(t)
	out := ack(t, root, "", "--task", "t1", "--files", root+"/.ai/knowledge/a.md")
	if text(out) != "acknowledged 1 document(s) for t1\n" || !strings.Contains(read(root, ".ai/workspace/tasks/t1/context"), "\t.ai/knowledge/a.md\t-\n") {
		t.Errorf("%q", text(out))
	}
}

func TestAcknowledgeLinkedSourceRules(t *testing.T) {
	root := ackFixture(t)
	// The source of a resolvable stub is acknowledged in the stub's place; another file is not.
	if out := ack(t, root, "", "--task", "t1", "--files", "docs/real.md"); out.Code != 0 {
		t.Errorf("%q", text(out))
	}
	write(t, root, "docs/other.md", "x\n")
	if out := ack(t, root, "", "--task", "t1", "--files", "docs/other.md"); !strings.Contains(text(out), "not a knowledge document or a linked source: docs/other.md") {
		t.Errorf("%q", text(out))
	}
	// A stub that is not resolvable links nothing.
	knowledgeDoc(t, root, "stub.md", "k-stub", "proposed", "source: docs/real.md\n")
	if out := ack(t, root, "", "--task", "t1", "--files", "docs/real.md"); !strings.Contains(text(out), "not a knowledge document or a linked source: docs/real.md") {
		t.Errorf("%q", text(out))
	}
}
