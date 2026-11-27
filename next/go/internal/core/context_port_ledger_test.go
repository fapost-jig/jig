package core

// Counterparts of tests/context.t.sh, see context_port_test.go: the context
// ledger, `jig context guard`, `pending` and `acknowledge`.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func (c *cp) checkoutLoadAlways() {
	c.doc("features/checkout.md", "id: feature-checkout", "type: feature", "status: active", "load: always")
}

// ackDoc is ctx_ack_doc.
func (c *cp) ackDoc() {
	c.doc("features/checkout.md", "id: feature-checkout", "type: feature", "status: active", "paths:", `  - "src/**"`)
}

// pendingAck is `jig context pending --task T-1 [more] | jig context
// acknowledge --task T-1 --files -`.
func (c *cp) pendingAck(more ...string) cres {
	c.t.Helper()
	return c.pipe(append([]string{"pending", "--task", "T-1"}, more...), "--task", "T-1", "--files", "-")
}

// ledgerPaths is `cut -f2` of the task's ledger.
func (c *cp) ledgerCol(id string, cols ...int) []string {
	var out []string
	for _, l := range strings.Split(strings.TrimRight(c.read(".ai/workspace/tasks/"+id+"/context"), "\n"), "\n") {
		if l == "" {
			continue
		}
		f := strings.Split(l, "\t")
		var picked []string
		for _, n := range cols {
			if n <= len(f) {
				picked = append(picked, f[n-1])
			}
		}
		out = append(out, strings.Join(picked, "\t"))
	}
	return out
}

// The ledger and the cache live in the task's workspace, so they are written
// under the same rule as `state`: through a link that leads outside the
// repository, acknowledging is refused and the cache is simply not written.
func TestContext_writers_refuse_a_planted_tasks_link(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.checkoutLoadAlways()
	tasks := filepath.Join(c.root, ".ai/workspace/tasks")
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.Rename(tasks, outside); err != nil {
		t.Fatal(err)
	}
	symlinkOrSkip(t, outside, tasks)

	r := c.run("acknowledge", "--task", "T-1", "--files", ".ai/knowledge/features/checkout.md")
	r.rc(1)
	r.has("context acknowledge: .ai/workspace/tasks leads to")
	if _, err := os.Stat(filepath.Join(outside, "T-1/context")); err == nil {
		t.Error("the ledger was written through the link")
	}
	r = c.run("--task", "T-1", "--files", "src/a.php")
	r.rc(0)
	if _, err := os.Stat(filepath.Join(outside, "T-1/context-cache")); err == nil {
		t.Error("the cache was written through the link")
	}
}

func TestContext_guard_ledger_round_trip(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.checkoutLoadAlways()
	r := c.run("guard", "--task", "T-1")
	r.rc(1)
	r.has("context guard: 4 of 4 document(s) not acknowledged:", "  .ai/knowledge/features/checkout.md",
		"read them, then: jig context acknowledge --task T-1 --files <list>")
	c.pendingAck().rc(0)
	r = c.run("guard", "--task", "T-1")
	r.rc(0)
	r.has("context guard: ok (4 document(s) acknowledged)")
}

func TestContext_guard_reacknowledges_after_document_changes(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.checkoutLoadAlways()
	c.pendingAck().rc(0)
	c.run("guard", "--task", "T-1").rc(0)

	c.write(".ai/knowledge/features/checkout.md", c.read(".ai/knowledge/features/checkout.md")+"extra line\n")

	r := c.run("guard", "--task", "T-1")
	r.rc(1)
	r.has("context guard: 1 of 4 document(s) not acknowledged:", "  .ai/knowledge/features/checkout.md")
	r.lacks("GLOSSARY.md")
}

func TestContext_ledger_file_format_and_location(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.checkoutLoadAlways()
	c.pendingAck().rc(0)

	ledger := c.read(".ai/workspace/tasks/T-1/context")
	if ledger == "" {
		t.Fatal("no ledger at .ai/workspace/tasks/T-1/context")
	}
	var line string
	for _, l := range strings.Split(ledger, "\n") {
		if strings.Contains(l, "features/checkout.md") {
			line = l
		}
	}
	eq(t, c.blob(".ai/knowledge/features/checkout.md")+"\t.ai/knowledge/features/checkout.md\t-", line)

	lines := strings.Split(strings.TrimRight(ledger, "\n"), "\n")
	eq(t, strings.Join(sortedCopy(lines), "\n"), strings.Join(lines, "\n"))
}

func TestContext_workspace_artifacts_never_tracked_by_ledger(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.write(".ai/workspace/tasks/T-1/discovery.md", "# discovery\n")
	r := c.run("resolve", "--task", "T-1")
	r.rc(0)
	r.has("workspace: .ai/workspace/tasks/T-1/task.md", "workspace: .ai/workspace/tasks/T-1/discovery.md")
	r = c.run("pending", "--task", "T-1")
	r.rc(0)
	r.lacks("task.md", "discovery.md")
}

func TestContext_guard_and_pending_with_no_live_task(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1", "paused: true", "paused_reason: testing")
	r := c.run("guard")
	r.rc(0)
	r.is("context guard: no task workspace; nothing tracked")
	r = c.run("pending")
	r.rc(0)
	r.is("")
}

// --- acknowledge: path validation ----------------------------------------------------------

func TestContext_acknowledge_rejects_absolute_path(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	r := c.run("acknowledge", "--task", "T-1", "--files", "/etc/passwd")
	r.rc(1)
	r.has("context acknowledge: path must be repository-relative:")
}

func TestContext_acknowledge_rejects_dotdot_path(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	r := c.run("acknowledge", "--task", "T-1", "--files", "../escape.md")
	r.rc(1)
	r.has("path may not contain '..'")
}

func TestContext_acknowledge_rejects_path_outside_knowledge_dir(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.write("README.md", "# fixture\n")
	r := c.run("acknowledge", "--task", "T-1", "--files", "README.md")
	r.rc(1)
	r.has("not a knowledge document or a linked source: README.md")
}

func TestContext_acknowledge_rejects_nonexistent_document(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	r := c.run("acknowledge", "--task", "T-1", "--files", ".ai/knowledge/features/ghost.md")
	r.rc(1)
	r.has("no such document:")
}

// --- acknowledge: friction -----------------------------------------------------------------------

func TestContext_guard_names_why_each_document_is_owed(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.ackDoc()
	r := c.run("guard", "--task", "T-1", "--stage", "review", "--files", "src/a.php")
	r.rc(1)
	r.has("  .ai/knowledge/RULES.md  (global)", "  .ai/knowledge/features/checkout.md  (paths: src/**)",
		"read them, then: jig context acknowledge --task T-1 --stage review --files <list>")
	// pending stays a bare list: it is piped into acknowledge.
	r = c.run("pending", "--task", "T-1", "--files", "src/a.php")
	r.rc(0)
	r.has(".ai/knowledge/features/checkout.md")
	r.lacks("(paths:")
}

func TestContext_acknowledge_takes_dot_slash_and_absolute_project_paths(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.ackDoc()
	r := c.run("acknowledge", "--task", "T-1", "--files", "./.ai/knowledge/features/checkout.md,"+c.root+"/.ai/knowledge/RULES.md")
	r.rc(0)
	r.has("acknowledged 2 document(s) for T-1")
	paths := c.ledgerCol("T-1", 2)
	if len(paths) != 2 {
		t.Fatalf("ledger lines: %v", paths)
	}
	all := strings.Join(paths, "\n")
	if !strings.Contains(all, ".ai/knowledge/RULES.md") || !strings.Contains(all, ".ai/knowledge/features/checkout.md") {
		t.Errorf("ledger paths: %v", paths)
	}
}

func TestContext_acknowledge_refuses_a_batch_naming_every_bad_path(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.ackDoc()
	c.write("README.md", "# fixture\n")
	r := c.run("acknowledge", "--task", "T-1", "--files", ".ai/knowledge/features/checkout.md,README.md,../x.md,/etc/passwd")
	r.rc(1)
	r.has("context acknowledge: not a knowledge document or a linked source: README.md",
		"context acknowledge: path may not contain '..': ../x.md",
		"context acknowledge: path must be repository-relative: /etc/passwd",
		"context acknowledge: 3 path(s) refused; nothing recorded")
	if _, err := os.Stat(filepath.Join(c.root, ".ai/workspace/tasks/T-1/context")); err == nil {
		t.Error("a refused batch wrote the ledger")
	}
	// A refusal leaves no temporary file in the workspace.
	entries, _ := os.ReadDir(filepath.Join(c.root, ".ai/workspace/tasks/T-1"))
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "context.tmp.") {
			t.Errorf("temporary file left: %s", e.Name())
		}
	}
}

func TestContext_acknowledge_revoke_withdraws_an_acknowledgement(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.ackDoc()
	c.pendingAck("--files", "src/a.php").rc(0)
	c.run("guard", "--task", "T-1", "--files", "src/a.php").rc(0)

	r := c.run("acknowledge", "--task", "T-1", "--revoke", "--files", "./.ai/knowledge/features/checkout.md")
	r.rc(0)
	r.has("revoked 1 document(s) for T-1")
	r = c.run("guard", "--task", "T-1", "--files", "src/a.php")
	r.rc(1)
	r.has("context guard: 1 of 4 document(s) not acknowledged:")

	// Not in the ledger: the batch is refused and nothing changes.
	r = c.run("acknowledge", "--task", "T-1", "--revoke", "--files", ".ai/knowledge/RULES.md,.ai/knowledge/features/checkout.md")
	r.rc(1)
	r.has("not acknowledged for this task: .ai/knowledge/features/checkout.md")
	if !strings.Contains(strings.Join(c.ledgerCol("T-1", 2), "\n"), ".ai/knowledge/RULES.md") {
		t.Errorf("the refused revoke changed the ledger:\n%s", c.read(".ai/workspace/tasks/T-1/context"))
	}
}

func TestContext_acknowledge_revoke_refuses_a_stage(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.ackDoc()
	c.run("acknowledge", "--task", "T-1", "--stage", "implement", "--files", ".ai/knowledge/features/checkout.md")
	// A revoke drops the line whatever stage it was made at: a stage given with
	// it is refused, in either order, and the ledger is left as it was.
	r := c.run("acknowledge", "--task", "T-1", "--revoke", "--stage", "review", "--files", ".ai/knowledge/features/checkout.md")
	r.rc(1)
	r.has("context acknowledge: --revoke takes no --stage")
	r = c.run("acknowledge", "--task", "T-1", "--stage", "implement", "--revoke", "--files", ".ai/knowledge/features/checkout.md")
	r.rc(1)
	r.has("context acknowledge: --revoke takes no --stage")
	eq(t, ".ai/knowledge/features/checkout.md\timplement", strings.Join(c.ledgerCol("T-1", 2, 3), "\n"))
}

func TestContext_acknowledge_revoke_takes_a_deleted_document(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.ackDoc()
	c.run("acknowledge", "--task", "T-1", "--files", ".ai/knowledge/features/checkout.md")
	removeFile(t, c.root, ".ai/knowledge/features/checkout.md")
	r := c.run("acknowledge", "--task", "T-1", "--revoke", "--files", ".ai/knowledge/features/checkout.md")
	r.rc(0)
	eq(t, "", strings.TrimRight(c.read(".ai/workspace/tasks/T-1/context"), "\n"))
}

func TestContext_guard_says_whose_acknowledgements_it_took(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.ackDoc()
	c.run("acknowledge", "--task", "T-1", "--stage", "implement", "--files",
		".ai/knowledge/GLOSSARY.md,.ai/knowledge/ARCHITECTURE.md,.ai/knowledge/RULES.md")
	// A line from before the stage field: two fields, read as no stage.
	c.write(".ai/workspace/tasks/T-1/context", c.read(".ai/workspace/tasks/T-1/context")+
		c.blob(".ai/knowledge/features/checkout.md")+"\t.ai/knowledge/features/checkout.md\n")
	for _, l := range strings.Split(c.read(".ai/workspace/tasks/T-1/context"), "\n") {
		if strings.Contains(l, "RULES.md") {
			eq(t, "implement", strings.Split(l, "\t")[2])
		}
	}

	r := c.run("guard", "--task", "T-1", "--stage", "review", "--files", "src/a.php")
	r.rc(0)
	r.has("context guard: ok (4 document(s) acknowledged)", "  3 acknowledged at implement", "  1 acknowledged at no stage",
		"  none acknowledged at review: this guard passed on acknowledgements made elsewhere")

	// Acknowledging again at review replaces the line, the old one included.
	r = c.run("acknowledge", "--task", "T-1", "--stage", "review", "--files", ".ai/knowledge/features/checkout.md")
	r.rc(0)
	r.has("acknowledged 1 document(s) for T-1 at review")
	if n := strings.Count(c.read(".ai/workspace/tasks/T-1/context"), "checkout.md"); n != 1 {
		t.Errorf("%d lines for checkout.md", n)
	}
	r = c.run("guard", "--task", "T-1", "--stage", "review", "--files", "src/a.php")
	r.has("  1 acknowledged at review")
	r.lacks("none acknowledged")
}

func TestContext_acknowledge_refuses_an_unknown_stage(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	r := c.run("acknowledge", "--task", "T-1", "--stage", "reading", "--files", ".ai/knowledge/RULES.md")
	r.rc(1)
	r.has("context: invalid stage: reading")
}

// --- acknowledge: a linked source is acknowledged in its stub's place -------------------------------

func TestContext_acknowledge_accepts_the_source_of_an_accepted_stub(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	c.newTask("T-1")
	r := c.run("acknowledge", "--task", "T-1", "--files", "docs/style.md")
	r.rc(0)
	var line string
	for _, l := range strings.Split(c.read(".ai/workspace/tasks/T-1/context"), "\n") {
		if strings.Contains(l, "docs/style.md") {
			line = l
		}
	}
	eq(t, c.blob("docs/style.md")+"\tdocs/style.md\t-", line)
}

func TestContext_acknowledge_refuses_a_linked_source_swapped_for_a_symlink(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	c.newTask("T-1")
	removeFile(t, c.root, "docs/style.md")
	symlinkOrSkip(t, outsideFile(t), filepath.Join(c.root, "docs/style.md"))
	r := c.run("acknowledge", "--task", "T-1", "--files", "docs/style.md")
	r.rc(1)
	r.has("context acknowledge: no such document: docs/style.md")
	if _, err := os.Stat(filepath.Join(c.root, ".ai/workspace/tasks/T-1/context")); err == nil {
		t.Error("the ledger was written")
	}
}

func TestContext_acknowledge_refuses_the_source_of_a_still_proposed_stub(t *testing.T) {
	c := newCP(t)
	c.stubSetup()
	c.newTask("T-1")
	r := c.run("acknowledge", "--task", "T-1", "--files", "docs/style.md")
	r.rc(1)
	r.has("not a knowledge document or a linked source: docs/style.md")
}

func TestContext_pending_tracks_the_source_editing_the_source_reopens_it_editing_the_stub_metadata_does_not(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	// `load: always` keeps the stub required regardless of the selectors, so only
	// the ledger hash is under test.
	stub := ".ai/knowledge/sources/style.md"
	c.write(stub, strings.Replace(c.read(stub), "source: docs/style.md\n", "source: docs/style.md\nload: always\n", 1))
	c.newTask("T-1")
	c.run("acknowledge", "--task", "T-1", "--files", "docs/style.md").rc(0)

	r := c.run("pending", "--task", "T-1")
	r.rc(0)
	r.lacks("docs/style.md")

	// Editing the source makes the acknowledgement stale again.
	c.write("docs/style.md", c.read("docs/style.md")+"extra rule\n")
	r = c.run("pending", "--task", "T-1")
	r.rc(0)
	r.has("docs/style.md")

	// Re-acknowledge, then edit only the stub's own metadata: the ledger never
	// hashed the stub, so this must not reopen the acknowledgement.
	c.run("acknowledge", "--task", "T-1", "--files", "docs/style.md").rc(0)
	c.write(stub, strings.Replace(c.read(stub), "source: docs/style.md\n", "source: docs/style.md\nsummary: \"updated summary\"\n", 1))
	r = c.run("pending", "--task", "T-1")
	r.rc(0)
	r.lacks("docs/style.md")
}

func TestContext_acknowledge_requires_task(t *testing.T) {
	c := newCP(t)
	r := c.run("acknowledge", "--files", "x")
	r.rc(1)
	r.has("context acknowledge: --task is required")
}

func TestContext_acknowledge_requires_files(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	r := c.run("acknowledge", "--task", "T-1")
	r.rc(1)
	r.has("context acknowledge: --files is required")
}

// --- CLI plumbing: subcommands ----------------------------------------------------------------------

func TestContext_unknown_subcommand_dies_with_usage(t *testing.T) {
	c := newCP(t)
	r := c.run("bogus")
	r.rc(1)
	r.has("usage: jig context")
}
