package core

// Counterparts of tests/context.t.sh, see context_port_test.go: the task's place
// in the queue, the pause request honoured where a stage begins, and the links to
// a neighbouring repository's task or spec.

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

const queueHead = "# jig queue 1 — written by `jig queue` only; do not edit by hand\n"

// queueSetup is _ctxq_setup: a filed task for each of ids, and the task on linked
// to a spec whose roadmap declares an open epic. The queue is what `jig queue move
// a --top`, `move b --bottom` and `set t1 --priority 0` leave, with t1 waiting for
// a, plus the pause request when request is not "".
func (c *cp) queueSetup(spec, on string, request string, ids ...string) {
	c.t.Helper()
	for _, id := range ids {
		task(c.t, c.root, id, "task_id: "+id, "branch: task/"+id, "status: active", "knowledge_consolidated: false",
			"created_at: 2026-11-27", "updated_at: 2026-11-27")
	}
	c.write(".ai/specs/"+spec+"/spec.md", "# "+spec+"\n")
	c.write(".ai/specs/"+spec+"/roadmap.md", "# Roadmap\n\nEpic: epic/"+spec+"\n\n## Phase 1 — One\n")
	task(c.t, c.root, on, "task_id: "+on, "branch: task/"+on, "status: active", "knowledge_consolidated: false",
		"created_at: 2026-11-27", "updated_at: 2026-11-27")
	c.write(".ai/workspace/tasks/"+on+"/task.md", "# "+on+"\n\nSpec: .ai/specs/"+spec+"/ — Phase 1\n")
	q := queueHead +
		"item\ttask:a\t-\t100\t-\n" +
		"item\ttask:b\t-\t200\t-\n" +
		"item\ttask:" + on + "\tepic:" + spec + "\t100\t0\n" +
		"dep\ttask:" + on + "\ttask:a\tneeds a\n" + request
	c.write(".ai/runtime/queue", q)
}

func TestContext_shows_the_tasks_place_in_the_queue(t *testing.T) {
	c := newCP(t)
	// The request is years old, so its age is counted in days and no test meets a
	// minute boundary (_ctxq_age_request).
	c.queueSetup("big", "t1", "request\ttask:t1\tpause\t2020-01-01T00:00:00Z\tstandup\n", "a", "b", "c")
	r := c.run("--task", "t1", "--files", "x")
	r.rc(0)
	r.has("queue:     1 of 1 on epic:big, priority 0", "queue:     waits for task:a: needs a")
	if !regexp.MustCompile(`(?m)^queue: +pause requested [0-9]+ days ago \(standup\); honoured when the next stage of the task resolves its context$`).MatchString(r.Out) {
		t.Errorf("no pause request:\n%s", r.Out)
	}
	// Without --stage, resolve enters no stage: it shows the request too.
	r = c.run("resolve", "--task", "t1", "--files", "x")
	r.rc(0)
	r.has("pause requested", "queue:     1 of 1 on epic:big, priority 0", "queue:     waits for task:a: needs a")
	r = c.run("--task", "a", "--files", "x")
	r.has("queue:     1 of 2 on the top level, no priority")
	// The paths form stays paths alone.
	r = c.run("--task", "t1", "--files", "x", "--format", "paths")
	r.lacks("queue")
	r = c.run("--task", "c", "--files", "x")
	r.lacks("queue:")
}

// --- a pause request honoured where a stage begins -----------------------------------------------
// A stage skill's first step is `jig context resolve --task <id> --stage <stage>`: a
// pending request pauses the task there, and no context is printed.

func TestContext_resolve_with_a_stage_honours_a_pause_request(t *testing.T) {
	c := newCP(t)
	at := "2023-11-14T22:13:20Z"
	c.queueSetup("big", "t1", "request\ttask:t1\tpause\t"+at+"\tstandup\n", "a")
	r := c.run("resolve", "--task", "t1", "--stage", "implement", "--files", "x")
	r.rc(4)
	eq(t, "paused: t1 (pause requested at "+at+": standup); stage implement not entered", strings.SplitN(r.Out, "\n", 2)[0])
	r.has("next:      a person asked for this pause; do not start the implement stage, end the session; jig task resume t1 continues the task")
	r.lacks("global:")
	if !strings.Contains(c.read(".ai/workspace/tasks/t1/state"), "\npaused: true\n") {
		t.Errorf("state:\n%s", c.read(".ai/workspace/tasks/t1/state"))
	}
	if strings.Contains(c.read(".ai/runtime/queue"), "\nrequest") {
		t.Errorf("the request is still in the queue:\n%s", c.read(".ai/runtime/queue"))
	}
	// Paused, the next resolve reads as always: the pause is the person's to end.
	r = c.run("resolve", "--task", "t1", "--stage", "implement", "--files", "x")
	r.rc(0)
	r.has("global:")
	r.lacks("paused:")
}

// The commands an agent runs inside a stage, and a task guessed from the branch,
// pause nothing: only a named stage of a named task is its entry.
func TestContext_mid_stage_commands_leave_a_pause_request_standing(t *testing.T) {
	c := newCP(t)
	c.queueSetup("big", "t1", "request\ttask:t1\tpause\t2023-11-14T22:13:20Z\t\n", "a")
	c.run("resolve", "--task", "t1", "--files", "x").rc(0)
	c.run("guard", "--task", "t1", "--stage", "implement", "--files", "x")
	c.run("pending", "--task", "t1", "--stage", "implement", "--files", "x")
	c.run("--task", "t1", "--files", "x").rc(0)
	c.branch = "task/t1"
	r := c.run("resolve", "--stage", "implement", "--files", "x")
	r.lacks("paused:")
	if strings.Contains(c.read(".ai/workspace/tasks/t1/state"), "paused:") {
		t.Errorf("the task was paused:\n%s", c.read(".ai/workspace/tasks/t1/state"))
	}
	if !strings.Contains(c.read(".ai/runtime/queue"), "request\ttask:t1\tpause") {
		t.Errorf("the request left the queue:\n%s", c.read(".ai/runtime/queue"))
	}
	// Another task's request is not this one's.
	r = c.run("resolve", "--task", "a", "--stage", "implement", "--files", "x")
	r.rc(0)
	r.lacks("paused:")
}

// A pause that cannot be made leaves the request standing, sticky, and the context
// is printed as always: reading it never breaks on the queue.
func TestContext_resolve_prints_the_context_when_the_pause_is_refused(t *testing.T) {
	c := newCP(t)
	c.queueSetup("big", "t1", "request\ttask:t1\tpause\t2023-11-14T22:13:20Z\t\n", "a")
	runtime := filepath.Join(c.root, ".ai/runtime")
	// The queue cannot be written, so the request cannot be taken out.
	if err := os.Chmod(runtime, 0o555); err != nil {
		t.Skip("cannot chmod")
	}
	defer os.Chmod(runtime, 0o755)
	if f, err := os.Create(filepath.Join(runtime, "probe")); err == nil {
		f.Close()
		t.Skip("chmod 555 does not make a directory read-only here")
	}
	r := c.run("resolve", "--task", "t1", "--stage", "implement", "--files", "x")
	os.Chmod(runtime, 0o755)
	r.rc(0)
	r.has("global:", "jig: warning: context: the pause requested for t1 was not honoured")
	if strings.Contains(c.read(".ai/workspace/tasks/t1/state"), "paused:") {
		t.Errorf("the task was paused:\n%s", c.read(".ai/workspace/tasks/t1/state"))
	}
	if !strings.Contains(c.read(".ai/runtime/queue"), "request\ttask:t1\tpause") {
		t.Errorf("the request left the queue:\n%s", c.read(".ai/runtime/queue"))
	}
}

// --- links to a neighbouring repository's task or spec ---------------------------------------------

// neighbour is ctx_neighbour: a neighbouring repository's task workspace with a
// task.md and a design.md. Only the files resolve reads: it need not be a git
// repository.
func (c *cp) neighbour(repo, id string) {
	c.write(repo+"/.ai/workspace/tasks/"+id+"/task.md", "# "+id+"\n")
	c.write(repo+"/.ai/workspace/tasks/"+id+"/design.md", "# design of "+id+"\n")
}

// link is ctx_link: a `Linked:` line appended to the task's task.md.
func (c *cp) link(id, ref string) {
	p := ".ai/workspace/tasks/" + id + "/task.md"
	c.write(p, c.read(p)+"Linked: "+ref+"\n")
}

func TestContext_resolve_lists_a_linked_tasks_documents_marked_by_source(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.neighbour("packages/saas", "up")
	c.link("T-1", "packages/saas#up")
	d := c.root + "/packages/saas/.ai/workspace/tasks/up"
	r := c.run("resolve", "--task", "T-1")
	r.rc(0)
	r.has("linked:    "+d+"/task.md  (packages/saas#up)", "linked:    "+d+"/design.md  (packages/saas#up)")
	r.lacks("plan.md")
}

func TestContext_resolve_lists_a_linked_specs_documents(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	other := filepath.Join(filepath.Dir(c.root), "other")
	write(t, other, ".ai/specs/big/spec.md", "# spec\n")
	write(t, other, ".ai/specs/big/roadmap.md", "# roadmap\n")
	c.link("T-1", "../other#spec/big")
	d := other + "/.ai/specs/big"
	r := c.run("resolve", "--task", "T-1")
	r.rc(0)
	r.has("linked:    "+d+"/spec.md  (../other#spec/big)", "linked:    "+d+"/roadmap.md  (../other#spec/big)")
}

func TestContext_resolve_says_plainly_when_a_link_reaches_nothing(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	if err := os.MkdirAll(filepath.Join(c.root, "packages/empty"), 0o755); err != nil {
		t.Fatal(err)
	}
	c.link("T-1", "packages/gone#up")
	c.link("T-1", "packages/empty#up")
	c.link("T-1", "packages/empty#spec/big")
	c.link("T-1", "/abs/path#up")
	c.link("T-1", "packages/empty")
	r := c.run("resolve", "--task", "T-1")
	r.rc(0)
	r.has("linked:    packages/gone#up  unreachable: no repository at",
		"linked:    packages/empty#up  unreachable: no task up in",
		"linked:    packages/empty#spec/big  unreachable: no spec big in",
		"linked:    /abs/path#up  unreachable: malformed link: the repository path must be relative",
		"linked:    packages/empty  unreachable: malformed link: no # between")
}

func TestContext_links_are_read_only_for_a_task(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.neighbour("packages/saas", "up")
	c.link("T-1", "packages/saas#up")
	r := c.run("resolve", "--no-task", "--files", "README.md")
	r.rc(0)
	r.lacks("linked:")
}

// Integration test: a linked worktree of the clone is a checkout git itself
// describes, and its links are read from the main checkout.
func TestContext_a_worktree_resolves_links_from_the_main_checkout(t *testing.T) {
	c := newCP(t)
	c.write("README.md", "# fixture\n")
	gitReal(t, c.root, "init", "-q", "-b", "main")
	gitReal(t, c.root, "add", "-f", "README.md", ".ai/config.yaml", ".ai/knowledge")
	gitReal(t, c.root, "commit", "-q", "-m", "jig init snapshot")
	c.newTask("T-1")
	c.neighbour("packages/saas", "up")
	c.link("T-1", "packages/saas#up")
	d := c.root + "/packages/saas/.ai/workspace/tasks/up"

	wt := filepath.Join(filepath.Dir(c.root), "wt")
	gitReal(t, c.root, "worktree", "add", "-q", "-b", "task/T-1", wt)
	wt, err := filepath.EvalSymlinks(wt)
	if err != nil {
		t.Fatal(err)
	}
	// The worktree shares the clone's workspace, as `jig task start --worktree` links it.
	if err := os.MkdirAll(filepath.Join(wt, ".ai/workspace"), 0o755); err != nil {
		t.Fatal(err)
	}
	symlinkOrSkip(t, filepath.Join(c.root, ".ai/workspace/tasks"), filepath.Join(wt, ".ai/workspace/tasks"))
	if _, err := os.Stat(filepath.Join(wt, "packages/saas/.ai/workspace/tasks/up/task.md")); err == nil {
		t.Fatal("the worktree holds the neighbour itself")
	}

	w := &cp{t: t, root: wt}
	r := w.realRun("resolve", "--task", "T-1")
	r.rc(0)
	r.has("linked:    " + d + "/design.md  (packages/saas#up)")
}

func TestContext_ledger_tracks_linked_documents_and_their_changes(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.neighbour("packages/saas", "up")
	c.link("T-1", "packages/saas#up")
	d := c.root + "/packages/saas/.ai/workspace/tasks/up"

	r := c.run("guard", "--task", "T-1")
	r.rc(1)
	r.has("  "+d+"/design.md", "  "+d+"/task.md")

	c.pendingAck().rc(0)
	c.run("guard", "--task", "T-1").rc(0)
	var line string
	for _, l := range strings.Split(c.read(".ai/workspace/tasks/T-1/context"), "\n") {
		if strings.Contains(l, "/design.md") {
			line = l
		}
	}
	eq(t, c.blob("packages/saas/.ai/workspace/tasks/up/design.md")+"\t"+d+"/design.md\t-", line)

	r = c.run("resolve", "--task", "T-1")
	r.has("linked:    " + d + "/design.md  (packages/saas#up)")

	c.write("packages/saas/.ai/workspace/tasks/up/design.md", c.read("packages/saas/.ai/workspace/tasks/up/design.md")+"a decision changed\n")

	r = c.run("resolve", "--task", "T-1")
	r.rc(0)
	r.has("linked:    "+d+"/design.md  (packages/saas#up; changed since acknowledged)",
		"linked:    "+d+"/task.md  (packages/saas#up)")
	r = c.run("guard", "--task", "T-1")
	r.rc(1)
	r.has("context guard: 1 of", "  "+d+"/design.md")
}

func TestContext_acknowledge_takes_only_the_absolute_paths_a_link_reaches(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.neighbour("packages/saas", "up")
	c.write("packages/saas/notes.md", "secret\n")
	c.link("T-1", "packages/saas#up")

	// Inside the project, an absolute path is read as the repository-relative one
	// it names, and that is no knowledge document either.
	r := c.run("acknowledge", "--task", "T-1", "--files", c.root+"/packages/saas/notes.md")
	r.rc(1)
	r.has("not a knowledge document or a linked source: packages/saas/notes.md")

	r = c.run("acknowledge", "--task", "T-1", "--files", c.root+"/packages/saas/.ai/workspace/tasks/up/task.md")
	r.rc(0)
	r.has("acknowledged 1 document(s) for T-1")
}

func TestContext_a_link_back_to_the_task_itself_gives_nothing(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.write(".ai/workspace/tasks/T-1/design.md", "# design\n")
	c.link("T-1", ".#T-1")
	r := c.run("resolve", "--task", "T-1")
	r.rc(0)
	r.has("linked:    .#T-1  unreachable: this is the task itself")
	r = c.run("pending", "--task", "T-1")
	r.lacks("design.md")
}
