package core

// These tests are the Go counterparts of tests/context.t.sh: one test per bash
// test, named after it by the rule TestEveryContextShTestHasACounterpart states
// (test_context_x becomes TestContext_x), with the same inputs and the same
// assertions on output, exit status and files. This file holds the shared
// helpers and the stateless form of `jig context`; the others are split by
// subcommand: context_port_resolve_test.go, context_port_ledger_test.go,
// context_port_stage_test.go and context_port_queue_test.go.
//
// Git is answered by proc.Fake except in the few tests marked "integration" in
// their comment, which are about what git itself says.

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/proc"
	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// cp is a project the way `jig init` leaves it (the three globals, the
// knowledge directories) with the means to run `jig context` in it.
type cp struct {
	t      *testing.T
	root   string
	branch string
	git    map[string]proc.Reply
	stdin  string
}

// newCP is ctx_setup.
func newCP(t *testing.T) *cp {
	t.Helper()
	root := fixture(t)
	for _, g := range []string{"GLOSSARY.md", "ARCHITECTURE.md", "RULES.md"} {
		write(t, root, ".ai/knowledge/"+g, "# "+g+"\n")
	}
	return &cp{t: t, root: root, branch: "main"}
}

// cres is what one `jig context` run printed: stdout and stderr together, as
// the bash tests' $OUT, and the stdout alone for what a pipe carries.
type cres struct {
	t    *testing.T
	Code int
	Out  string
	Std  string
}

// run is `jig context <args>` in the project.
func (c *cp) run(args ...string) cres {
	c.t.Helper()
	ctx, _ := ctxFor(c.root, c.branch, nil, c.git)
	if c.stdin != "" {
		ctx.Stdin = strings.NewReader(c.stdin)
	}
	return c.result(Context(ctx, args))
}

func (c *cp) result(o Output) cres {
	var all, std strings.Builder
	for _, ch := range o.Chunks {
		all.WriteString(ch.Text)
		if !ch.Stderr {
			std.WriteString(ch.Text)
		}
	}
	return cres{t: c.t, Code: o.Code, Out: strings.TrimRight(all.String(), "\n"), Std: std.String()}
}

// pipe is `jig context <first> | jig context acknowledge <ack>`: the stdout of
// the first is the standard input of the second.
func (c *cp) pipe(first []string, ack ...string) cres {
	c.t.Helper()
	r := c.run(first...)
	saved := c.stdin
	c.stdin = r.Std
	defer func() { c.stdin = saved }()
	if c.stdin == "" {
		c.stdin = "\n"
	}
	return c.run(append([]string{"acknowledge"}, ack...)...)
}

// rc is assert_eq <want> "$RC".
func (r cres) rc(want int) {
	r.t.Helper()
	if r.Code != want {
		r.t.Errorf("exit %d, want %d; output:\n%s", r.Code, want, r.Out)
	}
}

// has is assert_contains for each of subs.
func (r cres) has(subs ...string) {
	r.t.Helper()
	for _, s := range subs {
		if !strings.Contains(r.Out, s) {
			r.t.Errorf("output lacks %q:\n%s", s, r.Out)
		}
	}
}

// lacks is assert_not_contains for each of subs.
func (r cres) lacks(subs ...string) {
	r.t.Helper()
	for _, s := range subs {
		if strings.Contains(r.Out, s) {
			r.t.Errorf("output holds %q:\n%s", s, r.Out)
		}
	}
}

// is is assert_eq <want> "$OUT".
func (r cres) is(want string) {
	r.t.Helper()
	if r.Out != want {
		r.t.Errorf("output %q, want %q", r.Out, want)
	}
}

func eq(t *testing.T, want, got string) {
	t.Helper()
	if want != got {
		t.Errorf("got %q, want %q", got, want)
	}
}

// doc writes a knowledge document whose frontmatter is the given lines.
func (c *cp) doc(rel string, fm ...string) {
	c.t.Helper()
	write(c.t, c.root, ".ai/knowledge/"+rel, "---\n"+strings.Join(fm, "\n")+"\n---\n")
}

// newTask is `jig task new <id>`: a workspace with a state and a task.md. The
// extra lines are more state keys.
func (c *cp) newTask(id string, state ...string) {
	c.t.Helper()
	task(c.t, c.root, id, append([]string{"task_id: " + id, "status: active", "knowledge_consolidated: false",
		"created_at: 2026-11-27", "updated_at: 2026-11-27"}, state...)...)
	write(c.t, c.root, ".ai/workspace/tasks/"+id+"/task.md", "# "+id+"\n")
}

func (c *cp) read(rel string) string { return read(c.root, rel) }

func (c *cp) write(rel, text string) { write(c.t, c.root, rel, text) }

// gitReal runs a real git in the project, for the integration tests.
func gitReal(t *testing.T, root string, args ...string) {
	t.Helper()
	r, err := proc.Real().Run(proc.Cmd{Name: "git", Dir: root, Args: append([]string{
		"-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"}, args...)})
	if err != nil {
		t.Skipf("git %v: %v", args, err)
	}
	if r.Code != 0 {
		t.Fatalf("git %v: %+v", args, r)
	}
}

// realRun is `jig context <args>` against the real git of the project.
func (c *cp) realRun(args ...string) cres {
	c.t.Helper()
	return c.result(Context(Ctx{Exec: proc.Real(), Clock: mustClock(""), Env: func(string) string { return "" }, Cwd: c.root}, args))
}

// blob is `git hash-object` of a file of the project.
func (c *cp) blob(rel string) string { return storage.BlobSHA1([]byte(c.read(rel))) }

// removeFile is rm of a file of the project.
func removeFile(t *testing.T, root, rel string) {
	t.Helper()
	if err := os.Remove(filepath.Join(root, filepath.FromSlash(rel))); err != nil {
		t.Fatal(err)
	}
}

func sortedCopy(lines []string) []string {
	s := append([]string(nil), lines...)
	sort.Strings(s)
	return s
}

// --- --files: paths glob matching ---------------------------------------------

func TestContext_files_glob_double_star_any_depth(t *testing.T) {
	c := newCP(t)
	c.doc("features/flow.md", "id: feature-flow", "type: feature", "status: active", "paths:", `  - "src/Flow/**"`)
	r := c.run("--files", "src/Flow/A.php")
	r.rc(0)
	r.has("matched:   .ai/knowledge/features/flow.md  (paths: src/Flow/**)")
}

func TestContext_files_glob_takes_question_mark_and_brackets_literally(t *testing.T) {
	c := newCP(t)
	c.doc("features/literal.md", "id: feature-literal", "type: feature", "status: active", "paths:", `  - "src/a?b[c].php"`)
	c.run("--files", "src/axbc.php").lacks("literal.md")
	c.run("--files", "src/a?b[c].php").has("literal.md")
}

func TestContext_files_glob_ending_in_a_slash_covers_the_directory(t *testing.T) {
	c := newCP(t)
	c.doc("features/dir.md", "id: feature-dir", "type: feature", "status: active", "paths:", "  - src/Dir/")
	c.run("--files", "src/Dir/A.php").has("dir.md")
}

func TestContext_files_glob_single_segment_prefix(t *testing.T) {
	c := newCP(t)
	c.doc("features/trigger.md", "id: feature-trigger", "type: feature", "status: active", "paths:", `  - "app/Services/Trigger*"`)
	r := c.run("--files", "app/Services/TriggerService.php")
	r.rc(0)
	r.has("matched:   .ai/knowledge/features/trigger.md  (paths: app/Services/Trigger*)")
	// does not match a nested path
	r = c.run("--files", "app/Services/Other/TriggerService.php")
	r.rc(0)
	r.lacks("trigger.md")
}

func TestContext_files_glob_any_depth_extension(t *testing.T) {
	c := newCP(t)
	c.doc("conventions/shellish.md", "id: convention-shellish", "type: convention", "status: active", "paths:", `  - "**/*.sh"`)
	r := c.run("--files", "scripts/lib/foo.sh")
	r.rc(0)
	r.has("matched:   .ai/knowledge/conventions/shellish.md  (paths: **/*.sh)")
	r = c.run("--files", "top.sh")
	r.rc(0)
	r.has("matched:   .ai/knowledge/conventions/shellish.md")
}

func TestContext_files_exact_match(t *testing.T) {
	c := newCP(t)
	c.doc("features/exact.md", "id: feature-exact", "type: feature", "status: active", "paths:", `  - "docs/EXAMPLE.md"`)
	r := c.run("--files", "docs/EXAMPLE.md")
	r.rc(0)
	r.has("matched:   .ai/knowledge/features/exact.md")
	r = c.run("--files", "docs/OTHER.md")
	r.rc(0)
	r.lacks("exact.md")
}

func TestContext_files_csv_list(t *testing.T) {
	c := newCP(t)
	c.doc("features/a.md", "id: feature-a", "type: feature", "status: active", "paths:", `  - "a.php"`)
	c.doc("features/b.md", "id: feature-b", "type: feature", "status: active", "paths:", `  - "b.php"`)
	r := c.run("--files", "a.php,b.php", "--format", "paths")
	r.rc(0)
	r.has(".ai/knowledge/features/a.md", ".ai/knowledge/features/b.md")
}

func TestContext_files_from_stdin(t *testing.T) {
	c := newCP(t)
	c.doc("features/a.md", "id: feature-a", "type: feature", "status: active", "paths:", `  - "a.php"`)
	c.stdin = "a.php\n"
	r := c.run("--files", "-")
	r.rc(0)
	r.has("features/a.md")
}

func TestContext_matched_docs_sorted_by_path(t *testing.T) {
	c := newCP(t)
	c.doc("features/zzz.md", "id: feature-zzz", "type: feature", "status: active", "paths:", `  - "x.php"`)
	c.doc("features/aaa.md", "id: feature-aaa", "type: feature", "status: active", "paths:", `  - "x.php"`)
	r := c.run("--files", "x.php", "--format", "paths")
	r.rc(0)
	var feats []string
	for _, l := range strings.Split(r.Out, "\n") {
		if strings.Contains(l, "features") {
			feats = append(feats, l)
		}
	}
	if len(feats) != 2 || !strings.Contains(feats[0], "aaa.md") || !strings.Contains(feats[1], "zzz.md") {
		t.Errorf("order: %v", feats)
	}
}

func TestContext_no_match_still_exits_0_with_only_global(t *testing.T) {
	c := newCP(t)
	r := c.run("--files", "nonexistent/path.php")
	r.rc(0)
	r.has("global:")
	r.lacks("matched:")
}

// --- domains --------------------------------------------------------------------

func (c *cp) adrTriggers() {
	c.doc("adr/0007-x.md", "id: adr-0007-x", "type: adr", "status: accepted", "date: 2026-01-01", "domains: [triggers]")
}

func TestContext_domains_explicit(t *testing.T) {
	c := newCP(t)
	c.adrTriggers()
	r := c.run("--domains", "triggers")
	r.rc(0)
	r.has("matched:   .ai/knowledge/adr/0007-x.md  (domains: triggers)")
}

func TestContext_domains_from_task_state(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1", "domains: triggers,flow")
	c.adrTriggers()
	r := c.run("--task", "T-1")
	r.rc(0)
	r.has("matched:   .ai/knowledge/adr/0007-x.md  (domains: triggers)")
}

func TestContext_explicit_domains_override_task_domains(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1", "domains: other")
	c.adrTriggers()
	r := c.run("--task", "T-1", "--domains", "triggers")
	r.rc(0)
	r.has("adr/0007-x.md")
}

func TestContext_no_domains_no_match_on_domains(t *testing.T) {
	c := newCP(t)
	c.adrTriggers()
	r := c.run()
	r.rc(0)
	r.lacks("0007-x.md")
}

// --- git-derived files ------------------------------------------------------------

// Integration test: the union of the committed, unstaged and untracked files is
// what a real git says.
func TestContext_git_derived_union_of_committed_unstaged_untracked(t *testing.T) {
	c := newCP(t)
	c.doc("features/committed.md", "id: feature-committed", "type: feature", "status: active", "paths:", `  - "committed.php"`)
	c.doc("features/modified.md", "id: feature-modified", "type: feature", "status: active", "paths:", `  - "README.md"`)
	c.doc("features/untracked.md", "id: feature-untracked", "type: feature", "status: active", "paths:", `  - "new.php"`)
	c.write("README.md", "# fixture\n")
	gitReal(t, c.root, "init", "-q", "-b", "main")
	gitReal(t, c.root, "add", "README.md")
	gitReal(t, c.root, "commit", "-q", "-m", "init")
	gitReal(t, c.root, "checkout", "-q", "-b", "feature")
	c.write("committed.php", "<?php\n")
	gitReal(t, c.root, "add", "committed.php")
	gitReal(t, c.root, "commit", "-q", "-m", "add committed.php")
	c.write("README.md", "# fixture\nunstaged change\n")
	c.write("new.php", "<?php\n")

	r := c.realRun("--format", "paths")
	r.rc(0)
	r.has(".ai/knowledge/features/committed.md", ".ai/knowledge/features/modified.md", ".ai/knowledge/features/untracked.md")
}

func TestContext_git_missing_base_branch_falls_back_to_working_tree_only(t *testing.T) {
	c := newCP(t)
	c.doc("features/committed.md", "id: feature-committed", "type: feature", "status: active", "paths:", `  - "committed.php"`)
	c.doc("features/untracked.md", "id: feature-untracked", "type: feature", "status: active", "paths:", `  - "new.php"`)
	c.write(".ai/config.yaml", "git.base_branch: does-not-exist\n")
	c.branch = "feature"
	// committed.php was only reachable through the merge-base diff, which is
	// skipped when the base branch does not exist.
	c.git = map[string]proc.Reply{
		gitKey(c.root, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/does-not-exist^{commit}"): {Code: 1},
		gitKey(c.root, "rev-parse", "--verify", "--quiet", "refs/heads/does-not-exist^{commit}"):          {Code: 1},
		gitKey(c.root, "diff", "--cached", "--name-only"):                                                 {},
		gitKey(c.root, "diff", "--name-only"):                                                             {},
		gitKey(c.root, "ls-files", "--others", "--exclude-standard"):                                      {Stdout: "new.php\n"},
	}
	r := c.run("--format", "paths")
	r.rc(0)
	r.lacks("committed.md")
	r.has(".ai/knowledge/features/untracked.md")
}

// Integration test: a task cut from an epic branch (ADR-0039) sees its own
// commit and not the epic's, until its base is dropped.
func TestContext_git_derived_respects_the_tasks_own_base(t *testing.T) {
	c := newCP(t)
	c.doc("features/epiconly.md", "id: feature-epiconly", "type: feature", "status: active", "paths:", `  - "epic.php"`)
	c.doc("features/ownonly.md", "id: feature-ownonly", "type: feature", "status: active", "paths:", `  - "own.php"`)
	c.write("README.md", "# fixture\n")
	gitReal(t, c.root, "init", "-q", "-b", "main")
	gitReal(t, c.root, "add", "README.md")
	gitReal(t, c.root, "commit", "-q", "-m", "init")
	gitReal(t, c.root, "checkout", "-q", "-b", "epic/x")
	c.write("epic.php", "<?php\n")
	gitReal(t, c.root, "add", "epic.php")
	gitReal(t, c.root, "commit", "-q", "-m", "epic work")
	gitReal(t, c.root, "checkout", "-q", "-b", "task/kt", "epic/x")
	c.write("own.php", "<?php\n")
	gitReal(t, c.root, "add", "own.php")
	gitReal(t, c.root, "commit", "-q", "-m", "own work")
	c.newTask("T-1", "base_branch: epic/x")

	r := c.realRun("--task", "T-1", "--format", "paths")
	r.rc(0)
	r.has("ownonly.md")
	r.lacks("epiconly.md")

	// No task named: the configured base (main) answers, and the epic's own
	// commit, never on main, is touched again.
	r = c.realRun("--format", "paths")
	r.rc(0)
	r.has("ownonly.md", "epiconly.md")
}

// --- status filtering --------------------------------------------------------------

func TestContext_skips_superseded_deprecated_rejected_unless_all(t *testing.T) {
	c := newCP(t)
	c.doc("features/old.md", "id: feature-old", "type: feature", "status: superseded", "paths:", `  - "x.php"`)
	c.doc("adr/0001-old.md", "id: adr-0001-old", "type: adr", "status: rejected", "date: 2026-01-01", "paths:", `  - "x.php"`)
	r := c.run("--files", "x.php")
	r.rc(0)
	r.lacks("old.md")
	r = c.run("--files", "x.php", "--all")
	r.rc(0)
	r.has("features/old.md", "adr/0001-old.md")
}

func TestContext_active_status_always_shown(t *testing.T) {
	c := newCP(t)
	c.doc("features/active.md", "id: feature-active", "type: feature", "status: active", "paths:", `  - "x.php"`)
	r := c.run("--files", "x.php")
	r.rc(0)
	r.has("features/active.md")
}

func TestContext_status_proposed_not_matched_unless_all(t *testing.T) {
	c := newCP(t)
	c.doc("features/prop.md", "id: feature-prop", "type: feature", "status: proposed", "paths:", `  - "x.php"`)
	r := c.run("--files", "x.php")
	r.rc(0)
	r.lacks("prop.md")
	r = c.run("--files", "x.php", "--all")
	r.rc(0)
	r.has("matched:   .ai/knowledge/features/prop.md")
}

func TestContext_resolve_status_proposed_not_required_or_catalog_unless_all(t *testing.T) {
	c := newCP(t)
	c.doc("features/prop.md", "id: feature-prop", "type: feature", "status: proposed", "load: always", "domains: [payments]")
	r := c.run("resolve", "--domains", "payments", "--catalog")
	r.rc(0)
	r.lacks("required:  .ai/knowledge/features/prop.md", "catalog:   .ai/knowledge/features/prop.md")
	r = c.run("resolve", "--domains", "payments", "--catalog", "--all")
	r.rc(0)
	r.has("required:  .ai/knowledge/features/prop.md  (load: always)")
}

func TestContext_status_unknown_value_not_resolved_unless_all(t *testing.T) {
	c := newCP(t)
	// The allowlist rejects any status but the resolvable ones.
	c.doc("features/weird.md", "id: feature-weird", "type: feature", "status: banana", "paths:", `  - "x.php"`)
	r := c.run("--files", "x.php")
	r.rc(0)
	r.lacks("weird.md")
	r = c.run("--files", "x.php", "--all")
	r.rc(0)
	r.has("matched:   .ai/knowledge/features/weird.md")
	r = c.run("resolve", "--files", "x.php")
	r.rc(0)
	r.lacks("weird.md")
}

// --- --format paths ------------------------------------------------------------------

func TestContext_format_paths_prints_only_paths_no_prefixes(t *testing.T) {
	c := newCP(t)
	c.doc("features/x.md", "id: feature-x", "type: feature", "status: active", "paths:", `  - "x.php"`)
	r := c.run("--files", "x.php", "--format", "paths")
	r.rc(0)
	r.lacks("global:", "matched:", "(")
	r.has(".ai/knowledge/GLOSSARY.md", ".ai/knowledge/features/x.md")
}

// --- global files ------------------------------------------------------------------------

func TestContext_global_files_present(t *testing.T) {
	c := newCP(t)
	r := c.run()
	r.rc(0)
	r.has("global:    .ai/knowledge/GLOSSARY.md", "global:    .ai/knowledge/ARCHITECTURE.md", "global:    .ai/knowledge/RULES.md")
}

func TestContext_global_files_absent_are_omitted(t *testing.T) {
	c := newCP(t)
	removeFile(t, c.root, ".ai/knowledge/ARCHITECTURE.md")
	r := c.run()
	r.rc(0)
	r.has("global:    .ai/knowledge/GLOSSARY.md")
	r.lacks("ARCHITECTURE.md")
}

// --- workspace listing -----------------------------------------------------------------------

func TestContext_workspace_lists_task_md_only_by_default(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	r := c.run("--task", "T-1")
	r.rc(0)
	r.has("workspace: .ai/workspace/tasks/T-1/task.md")
}

func TestContext_workspace_lists_existing_artifacts_in_order(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.write(".ai/workspace/tasks/T-1/discovery.md", "# discovery\n")
	c.write(".ai/workspace/tasks/T-1/plan.md", "# plan\n")
	c.write(".ai/workspace/tasks/T-1/verification.md", "# verification\n")
	r := c.run("--task", "T-1")
	r.rc(0)
	r.has("workspace: .ai/workspace/tasks/T-1/task.md", "workspace: .ai/workspace/tasks/T-1/discovery.md",
		"workspace: .ai/workspace/tasks/T-1/plan.md", "workspace: .ai/workspace/tasks/T-1/verification.md")
	r.lacks("spec.md", "design.md", "review.md")
	// task.md before discovery.md before plan.md before verification.md
	at := func(s string) int { return strings.Index(r.Out, s) }
	if !(at("task.md") < at("discovery.md") && at("discovery.md") < at("plan.md") && at("plan.md") < at("verification.md")) {
		t.Errorf("artifacts out of order:\n%s", r.Out)
	}
}

func TestContext_no_workspace_line_without_a_task(t *testing.T) {
	c := newCP(t)
	r := c.run()
	r.rc(0)
	r.lacks("workspace:")
}

// --- task resolution ---------------------------------------------------------------------------

func TestContext_resolves_task_via_current_branch(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1", "branch: task/T-1") // jig task start
	c.branch = "task/T-1"
	r := c.run()
	r.rc(0)
	r.has("workspace: .ai/workspace/tasks/T-1/task.md")
}

func TestContext_no_current_task_is_silent_not_fatal(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.branch = "other"
	r := c.run()
	r.rc(0)
	r.lacks("workspace:")
}

func TestContext_task_explicit_overrides_current_branch_resolution(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.branch = "other"
	c.newTask("T-2")
	r := c.run("--task", "T-1")
	r.rc(0)
	r.has("workspace: .ai/workspace/tasks/T-1/task.md")
	r.lacks("T-2/task.md")
}

func TestContext_ambiguous_omits_workspace_warns_stderr_exits_0(t *testing.T) {
	c := newCP(t)
	// Two started tasks on one branch: a project with branch-per-task off.
	c.newTask("T-1", "branch: main")
	c.newTask("T-2", "branch: main")
	r := c.run()
	r.rc(0)
	r.lacks("workspace:")
	r.has("T-1", "T-2")
}

func TestContext_ambiguous_but_task_explicit_still_works(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.newTask("T-2")
	r := c.run("--task", "T-1")
	r.rc(0)
	r.has("workspace: .ai/workspace/tasks/T-1/task.md")
	r.lacks("T-2/task.md")
}

func TestContext_paused_task_excluded_leaves_one_candidate(t *testing.T) {
	c := newCP(t)
	// T-1 would win the tie-break by id, so pausing it is what exercises the exclusion.
	c.newTask("T-1", "branch: main", "paused: true")
	c.newTask("T-2", "branch: main")
	r := c.run()
	r.rc(0)
	r.has("workspace: .ai/workspace/tasks/T-2/task.md")
	r.lacks("T-1/task.md")
}

func TestContext_task_explicit_unknown_dies(t *testing.T) {
	c := newCP(t)
	r := c.run("--task", "NOPE")
	r.rc(1)
	r.has("unknown task")
}

// --- CLI plumbing ------------------------------------------------------------------------------

func TestContext_unknown_flag_dies(t *testing.T) {
	c := newCP(t)
	c.run("--bogus").rc(1)
}

func TestContext_invalid_format_dies(t *testing.T) {
	c := newCP(t)
	c.run("--format", "bogus").rc(1)
}

func TestContext_missing_value_for_files_dies(t *testing.T) {
	c := newCP(t)
	c.run("--files").rc(1)
}

func TestContext_without_init_dies(t *testing.T) {
	bare := t.TempDir()
	ctx, _ := ctxFor(bare, "main", nil, nil)
	r := (&cp{t: t}).result(Context(ctx, nil))
	r.rc(1)
	r.has("not initialised")
}

func TestContext_includes_staged_files_without_base_branch(t *testing.T) {
	c := newCP(t)
	// The base branch "main" no longer exists: the branch is called trunk.
	c.branch = "trunk"
	c.doc("features/flow.md", "id: feature-flow", "type: feature", "status: active", `paths: ["src/Flow/**"]`)
	c.git = map[string]proc.Reply{
		gitKey(c.root, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/main^{commit}"): {Code: 1},
		gitKey(c.root, "rev-parse", "--verify", "--quiet", "refs/heads/main^{commit}"):          {Code: 1},
		gitKey(c.root, "diff", "--cached", "--name-only"):                                       {Stdout: "src/Flow/A.php\n"},
		gitKey(c.root, "diff", "--name-only"):                                                   {},
		gitKey(c.root, "ls-files", "--others", "--exclude-standard"):                            {},
	}
	r := c.run("--format", "paths")
	r.rc(0)
	r.has(".ai/knowledge/features/flow.md")
}
