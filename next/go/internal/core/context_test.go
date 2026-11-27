package core

import (
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/proc"
)

func knowledgeDoc(t *testing.T, root, rel, id, status, extra string) {
	t.Helper()
	write(t, root, ".ai/knowledge/"+rel, "---\nid: "+id+"\ntype: feature\nstatus: "+status+"\n"+extra+"---\nbody\n")
}

func ctxRun(t *testing.T, root, branch string, table map[string]proc.Reply, args ...string) Output {
	t.Helper()
	ctx, _ := ctxFor(root, branch, nil, table)
	return Context(ctx, args)
}

func TestStatelessGlobalsMatchedAndWorkspace(t *testing.T) {
	root := fixture(t)
	write(t, root, ".ai/knowledge/RULES.md", "rules\n")
	write(t, root, ".ai/knowledge/GLOSSARY.md", "glossary\n")
	knowledgeDoc(t, root, "features/b.md", "feature-b", "active", "paths:\n  - src/b/**\n")
	knowledgeDoc(t, root, "features/a.md", "feature-a", "accepted", "paths: [src/**]\ndomains: [billing]\n")
	knowledgeDoc(t, root, "features/p.md", "feature-p", "proposed", "paths: [src/**]\n")
	knowledgeDoc(t, root, "features/s.md", "feature-s", "active", "load: stage\npaths: [src/**]\n")
	task(t, root, "t1", "status: active", "branch: feat", "domains: billing")
	write(t, root, ".ai/workspace/tasks/t1/task.md", "x")
	write(t, root, ".ai/workspace/tasks/t1/plan.md", "x")
	write(t, root, ".ai/workspace/tasks/t1/discovery.md", "x")

	out := ctxRun(t, root, "feat", nil, "--files", "src/b/x.go")
	want := "global:    .ai/knowledge/GLOSSARY.md\n" +
		"global:    .ai/knowledge/RULES.md\n" +
		"matched:   .ai/knowledge/features/a.md  (paths: src/**)\n" +
		"matched:   .ai/knowledge/features/b.md  (paths: src/b/**)\n" +
		"workspace: .ai/workspace/tasks/t1/task.md\n" +
		"workspace: .ai/workspace/tasks/t1/discovery.md\n" +
		"workspace: .ai/workspace/tasks/t1/plan.md\n"
	if out.Code != 0 || text(out) != want {
		t.Errorf("code %d\n%s\nwant\n%s", out.Code, text(out), want)
	}

	// --all lists the proposed one; the stage-only document never appears.
	out = ctxRun(t, root, "feat", nil, "--no-task", "--all", "--files", "src/x", "--format", "paths")
	if got := text(out); strings.Contains(got, "features/s.md") || !strings.Contains(got, ".ai/knowledge/features/p.md\n") || strings.Contains(got, "matched") {
		t.Errorf("--all --format paths: %q", got)
	}

	// Domains from the task, when no --files match.
	out = ctxRun(t, root, "feat", nil, "--files", "nothing")
	if got := text(out); !strings.Contains(got, "matched:   .ai/knowledge/features/a.md  (domains: billing)\n") {
		t.Errorf("domains: %q", got)
	}
}

func TestStatelessFilesFromStdin(t *testing.T) {
	root := fixture(t)
	knowledgeDoc(t, root, "f.md", "feature-f", "active", "paths: [lib/**]\n")
	ctx, _ := ctxFor(root, "main", nil, nil)
	ctx.Stdin = strings.NewReader("lib/x.go\nother\n\n")
	out := Context(ctx, []string{"--no-task", "--files", "-"})
	if want := "matched:   .ai/knowledge/f.md  (paths: lib/**)\n"; text(out) != want {
		t.Errorf("%q", text(out))
	}
}

func TestStatelessParseErrors(t *testing.T) {
	root := fixture(t)
	for _, tc := range []struct {
		args []string
		msg  string
	}{
		{[]string{"--bogus"}, "context: unknown argument: --bogus"},
		{[]string{"--files"}, "context: --files requires a value"},
		{[]string{"--task"}, "context: --task requires a value"},
		{[]string{"--format", "x"}, "context: invalid --format: x (want list or paths)"},
		{[]string{"--stage", "plan"}, "context: --stage requires the progressive form; use jig context resolve"},
		{[]string{"--task", "a", "--no-task"}, "context: --task conflicts with --no-task"},
		{[]string{"--task", "nope"}, "context: unknown task: nope"},
		{[]string{"--task", "../x"}, "invalid task id: ../x"},
		{[]string{"bogus"}, ctxUsage},
		{[]string{"resolve"}, "context resolve: not ported yet"},
	} {
		out := ctxRun(t, root, "main", nil, tc.args...)
		if out.Code != 1 || text(out) != "[err] jig: error: "+tc.msg+"\n" {
			t.Errorf("%v: %d %q", tc.args, out.Code, text(out))
		}
	}
}

func TestStatelessRefusesOutsideAProject(t *testing.T) {
	root := fixture(t)
	ctx, _ := ctxFor(root, "main", nil, map[string]proc.Reply{gitKey(root, "rev-parse", "--show-toplevel"): {Code: 128}})
	// ctxFor pins the answer last; build the failing Ctx directly.
	x, _ := proc.Fake(map[string]proc.Reply{gitKey(root, "rev-parse", "--show-toplevel"): {Code: 128}})
	ctx.Exec = x
	out := Context(ctx, nil)
	if out.Code != 1 || text(out) != "[err] jig: error: not inside a git repository\n" {
		t.Errorf("%d %q", out.Code, text(out))
	}
	bare := t.TempDir()
	ctx2, _ := ctxFor(bare, "main", nil, nil)
	out = Context(ctx2, nil)
	if text(out) != "[err] jig: error: project is not initialised; run: jig init\n" {
		t.Errorf("%q", text(out))
	}
}

func TestStatelessStubResolvesToItsSource(t *testing.T) {
	root := fixture(t)
	write(t, root, "docs/real.md", "real\n")
	knowledgeDoc(t, root, "stub.md", "stub-1", "active", "source: docs/real.md\npaths: [src/**]\n")
	out := ctxRun(t, root, "main", nil, "--no-task", "--files", "src/a")
	if want := "matched:   docs/real.md  (paths: src/**; linked by stub-1)\n"; text(out) != want {
		t.Errorf("%q", text(out))
	}
	write(t, root, ".ai/knowledge/gone.md", "---\nid: gone\nstatus: active\nsource: docs/missing.md\npaths: [src/**]\n---\n")
	out = ctxRun(t, root, "main", nil, "--no-task", "--files", "src/a")
	want := "[err] jig: error: context: .ai/knowledge/gone.md is selected but its source docs/missing.md is missing; fix the link or reject the stub\n"
	if out.Code != 1 || text(out) != want {
		t.Errorf("%d %q", out.Code, text(out))
	}
}

func TestStatelessAmbiguousCurrentTaskWarnsOnStderr(t *testing.T) {
	root := fixture(t)
	task(t, root, "a", "status: active", "branch: feat", "updated_at: 2026-01-02")
	task(t, root, "b", "status: ready", "branch: feat", "updated_at: 2026-01-03")
	task(t, root, "c", "status: active", "branch: feat", "paused: true")
	write(t, root, ".ai/knowledge/RULES.md", "r\n")
	out := ctxRun(t, root, "feat", nil, "--files", "x")
	want := "[err] a  active  updated_at=2026-01-02\nb  ready  updated_at=2026-01-03\nglobal:    .ai/knowledge/RULES.md\n"
	if out.Code != 0 || text(out) != want {
		t.Errorf("%d %q", out.Code, text(out))
	}
}

func TestStatelessShowsTheQueuePlace(t *testing.T) {
	root := fixture(t)
	task(t, root, "t1", "status: active", "branch: feat")
	write(t, root, ".ai/knowledge/RULES.md", "r\n")
	write(t, root, ".ai/runtime/queue", "# jig queue 1\n"+
		"item\ttask:t0\t-\t1\t2\n"+
		"item\ttask:t1\t-\t2\t-\n"+
		"dep\ttask:t1\ttask:t0\tneeds t0\n"+
		"request\ttask:t1\tpause\t2023-11-14T22:13:20Z\tlunch\n")
	out := ctxRun(t, root, "feat", nil, "--files", "x")
	want := "global:    .ai/knowledge/RULES.md\n" +
		"queue:     2 of 2 on the top level, no priority\n" +
		"queue:     waits for task:t0: needs t0\n" +
		"queue:     pause requested just now (lunch); honoured when the next stage of the task resolves its context\n"
	if text(out) != want {
		t.Errorf("%q", text(out))
	}
}

func TestStatelessTouchedFilesUnionAndTheTasksBase(t *testing.T) {
	root := fixture(t)
	knowledgeDoc(t, root, "f.md", "feature-f", "active", "paths: [\"**/*.go\"]\n")
	task(t, root, "t1", "status: active", "branch: feat", "base_branch: epic")
	table := map[string]proc.Reply{
		gitKey(root, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/epic^{commit}"): {Code: 1},
		gitKey(root, "rev-parse", "--verify", "--quiet", "refs/heads/epic^{commit}"):          {Stdout: "abc\n"},
		gitKey(root, "merge-base", "refs/heads/epic", "HEAD"):                                 {Stdout: "mb1\n"},
		gitKey(root, "diff", "--name-only", "mb1"):                                            {Stdout: "z.txt\nb.go\n"},
		gitKey(root, "diff", "--cached", "--name-only"):                                       {Stdout: "b.go\n"},
		gitKey(root, "diff", "--name-only"):                                                   {Stdout: "a.txt\n"},
		gitKey(root, "ls-files", "--others", "--exclude-standard"):                            {Stdout: "new.go\n"},
	}
	ctx, log := ctxFor(root, "feat", nil, table)
	got := touchedFiles(ctx, root, taskBase(Project{Root: root}, "t1"))
	if want := []string{"a.txt", "b.go", "new.go", "z.txt"}; strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("touched %v, want %v", got, want)
	}
	if u := log.Unexpected(); len(u) != 0 {
		t.Errorf("unexpected git calls: %v", u)
	}
	out := Context(ctx, nil)
	if !strings.Contains(text(out), "matched:   .ai/knowledge/f.md  (paths: **/*.go)\n") {
		t.Errorf("%q", text(out))
	}
}

func TestTouchedFilesWithoutABaseKeepsTheWorkingTree(t *testing.T) {
	root := fixture(t)
	table := map[string]proc.Reply{
		gitKey(root, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/main^{commit}"): {Code: 1},
		gitKey(root, "rev-parse", "--verify", "--quiet", "refs/heads/main^{commit}"):          {Code: 1},
		gitKey(root, "diff", "--cached", "--name-only"):                                       {Stdout: "staged\n"},
		gitKey(root, "diff", "--name-only"):                                                   {},
		gitKey(root, "ls-files", "--others", "--exclude-standard"):                            {Stdout: "u\n\n"},
	}
	ctx, _ := ctxFor(root, "main", nil, table)
	got := touchedFiles(ctx, root, "main")
	if strings.Join(got, ",") != "staged,u" {
		t.Errorf("%v", got)
	}
}
