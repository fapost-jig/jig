package core

import (
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/proc"
	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// progressiveFixture is a project with the three globals and a task on branch feat.
func progressiveFixture(t *testing.T) string {
	root := fixture(t)
	for _, g := range []string{"GLOSSARY.md", "ARCHITECTURE.md", "RULES.md"} {
		write(t, root, ".ai/knowledge/"+g, g+"\n")
	}
	task(t, root, "t1", "status: active", "branch: feat", "domains: billing")
	write(t, root, ".ai/workspace/tasks/t1/task.md", "goal\n")
	return root
}

func run(t *testing.T, root string, args ...string) Output {
	t.Helper()
	ctx, _ := ctxFor(root, "feat", nil, nil)
	return Context(ctx, args)
}

func TestBlobSHA1MatchesGit(t *testing.T) {
	if got := storage.BlobSHA1([]byte("hello\n")); got != "ce013625030ba8dba906f756967f9e9ca394464a" {
		t.Errorf("hello: %s", got)
	}
	if got := storage.BlobSHA1(nil); got != "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" {
		t.Errorf("empty: %s", got)
	}
}

func TestSelectReasonPolicies(t *testing.T) {
	root := progressiveFixture(t)
	knowledgeDoc(t, root, "always.md", "k-always", "active", "load: always\n")
	knowledgeDoc(t, root, "stage.md", "k-stage", "active", "load: stage\nstages: [review]\n")
	knowledgeDoc(t, root, "dom.md", "k-dom", "active", "load: domain\ndomains: [billing]\n")
	knowledgeDoc(t, root, "dompaths.md", "k-dp", "active", "load: domain\ndomains: [other]\npaths: [lib/**]\n")
	knowledgeDoc(t, root, "matched.md", "k-matched", "active", "domains: [billing]\n")
	knowledgeDoc(t, root, "topic.md", "k-topic", "active", "topics: [perf]\n")
	knowledgeDoc(t, root, "staged.md", "k-staged", "active", "stages: [plan]\ndomains: [billing]\n")
	knowledgeDoc(t, root, "old.md", "k-old", "superseded", "load: always\n")

	out := run(t, root, "resolve", "--task", "t1", "--files", "lib/x", "--topics", "perf", "--stage", "plan")
	want := "global:    .ai/knowledge/GLOSSARY.md\n" +
		"global:    .ai/knowledge/ARCHITECTURE.md\n" +
		"global:    .ai/knowledge/RULES.md\n" +
		"required:  .ai/knowledge/always.md  (load: always)\n" +
		"required:  .ai/knowledge/dom.md  (domains: billing)\n" +
		"required:  .ai/knowledge/dompaths.md  (paths: lib/**)\n" +
		"required:  .ai/knowledge/staged.md  (stage: plan; domain: billing)\n" +
		"required:  .ai/knowledge/topic.md  (topics: perf)\n" +
		"workspace: .ai/workspace/tasks/t1/task.md\n"
	if out.Code != 0 || text(out) != want {
		t.Errorf("%d\n%s\nwant\n%s", out.Code, text(out), want)
	}
	// The stage-only document is required at its stage, and `matched` by domain alone is not.
	out = run(t, root, "resolve", "--task", "t1", "--files", "x", "--stage", "review")
	if got := text(out); !strings.Contains(got, "required:  .ai/knowledge/stage.md  (load: stage; stage: review)\n") || strings.Contains(got, "matched.md") {
		t.Errorf("%s", got)
	}
}

func TestResolveCatalogIdsAndRequires(t *testing.T) {
	root := progressiveFixture(t)
	knowledgeDoc(t, root, "a.md", "k-a", "active", "paths: [src/**]\nrequires: [k-b]\n")
	knowledgeDoc(t, root, "b.md", "k-b", "active", "paths: [never/**]\nrequires: [k-c]\n")
	knowledgeDoc(t, root, "c.md", "k-c", "active", "paths: [never/**]\n")
	knowledgeDoc(t, root, "wide.md", "k-wide", "active", "summary: everywhere\n")
	knowledgeDoc(t, root, "dom.md", "k-dom", "active", "domains: [billing]\npaths: [never/**]\n")
	knowledgeDoc(t, root, "far.md", "k-far", "active", "domains: [other]\n")
	out := run(t, root, "resolve", "--no-task", "--domains", "billing", "--files", "src/a", "--ids", "k-far", "--catalog")
	want := "global:    .ai/knowledge/GLOSSARY.md\n" +
		"global:    .ai/knowledge/ARCHITECTURE.md\n" +
		"global:    .ai/knowledge/RULES.md\n" +
		"required:  .ai/knowledge/a.md  (paths: src/**)\n" +
		"required:  .ai/knowledge/b.md  (requires: k-a)\n" +
		"required:  .ai/knowledge/c.md  (requires: k-b)\n" +
		"required:  .ai/knowledge/far.md  (id: k-far)\n" +
		"catalog:   .ai/knowledge/dom.md  [k-dom] (no summary)\n" +
		"catalog:   .ai/knowledge/wide.md  [k-wide] everywhere\n"
	if text(out) != want {
		t.Errorf("%s\nwant\n%s", text(out), want)
	}
	out = run(t, root, "resolve", "--no-task", "--files", "x", "--ids", "nope")
	if out.Code != 1 || text(out) != "[err] jig: error: context: no active document with id: nope\n" {
		t.Errorf("%d %q", out.Code, text(out))
	}
	write(t, root, ".ai/knowledge/a.md", "---\nid: k-a\nstatus: active\npaths: [src/**]\nrequires: [k-zz]\n---\n")
	out = run(t, root, "resolve", "--no-task", "--files", "src/a")
	if want := "[err] jig: error: context: .ai/knowledge/a.md requires unknown or inactive document: k-zz; run: jig knowledge check\n"; text(out) != want {
		t.Errorf("%q", text(out))
	}
}

func TestSelectorErrors(t *testing.T) {
	root := progressiveFixture(t)
	for args, msg := range map[string]string{
		"resolve --stage bogus":    "context: invalid stage: bogus",
		"resolve --stage":          "context: --stage requires a value",
		"resolve --nope":           "context: unknown argument: --nope",
		"guard --task a --no-task": "context: --task conflicts with --no-task",
		"pending --task missing":   "context: unknown task: missing",
	} {
		out := run(t, root, strings.Fields(args)...)
		if out.Code != 1 || text(out) != "[err] jig: error: "+msg+"\n" {
			t.Errorf("%s: %d %q", args, out.Code, text(out))
		}
	}
	root2 := fixture(t)
	out := run(t, root2, "resolve", "--no-task")
	if text(out) != "[err] jig: error: context: missing or unreadable mandatory global: .ai/knowledge/GLOSSARY.md; restore project knowledge\n" {
		t.Errorf("%q", text(out))
	}
}

func TestCacheRoundTripAndInvalidation(t *testing.T) {
	root := progressiveFixture(t)
	knowledgeDoc(t, root, "a.md", "k-a", "active", "paths: [src/**]\n")
	// Without a git answer for the object format the hashes are sha1, in process.
	ctx, _ := ctxFor(root, "feat", nil, nil)
	first := Context(ctx, []string{"resolve", "--task", "t1", "--files", "src/a"})
	cache := read(root, ".ai/workspace/tasks/t1/context-cache")
	if !strings.HasPrefix(cache, "rule=domain-or-paths;stage-only\nstage=\nfiles=src/a\ndomains=billing\ntopics=\nids=\nall=0\n") ||
		!strings.HasSuffix(cache, "=== rows ===\n.ai/knowledge/a.md\tpaths: src/**\n") {
		t.Fatalf("cache:\n%s", cache)
	}
	// One hash for the one document (the globals are no part of the walk).
	if n := strings.Count(cache, "\n"); n != 7+1+1+1 {
		t.Errorf("%d lines:\n%s", n, cache)
	}
	// The cache decides: a rows line planted in it comes back while nothing changed.
	planted := strings.Replace(cache, "paths: src/**", "paths: PLANTED", 1)
	write(t, root, ".ai/workspace/tasks/t1/context-cache", planted)
	if got := text(Context(ctx, []string{"resolve", "--task", "t1", "--files", "src/a"})); !strings.Contains(got, "(paths: PLANTED)") {
		t.Errorf("the cache was not read:\n%s", got)
	}
	// A document whose bytes change changes the fingerprint: recomputed and rewritten.
	knowledgeDoc(t, root, "a.md", "k-a", "active", "paths: [src/**]\nsummary: changed\n")
	again := text(Context(ctx, []string{"resolve", "--task", "t1", "--files", "src/a"}))
	if strings.Contains(again, "PLANTED") || read(root, ".ai/workspace/tasks/t1/context-cache") == planted {
		t.Errorf("a stale cache was served:\n%s", again)
	}
	_ = first
	// No cache without a task.
	if out := Context(ctx, []string{"resolve", "--no-task", "--files", "src/a"}); out.Code != 0 {
		t.Error(text(out))
	}
}

func TestGuardPendingAndLedger(t *testing.T) {
	root := progressiveFixture(t)
	ctx, _ := ctxFor(root, "feat", nil, nil)
	args := []string{"--task", "t1", "--files", "x", "--stage", "plan"}
	g := Context(ctx, append([]string{"guard"}, args...))
	want := "[err] context guard: 3 of 3 document(s) not acknowledged:\n" +
		"  .ai/knowledge/ARCHITECTURE.md  (global)\n" +
		"  .ai/knowledge/GLOSSARY.md  (global)\n" +
		"  .ai/knowledge/RULES.md  (global)\n" +
		"read them, then: jig context acknowledge --task t1 --stage plan --files <list>\n"
	if g.Code != 1 || text(g) != want {
		t.Errorf("%d\n%s", g.Code, text(g))
	}
	p := Context(ctx, append([]string{"pending"}, args...))
	if text(p) != ".ai/knowledge/ARCHITECTURE.md\n.ai/knowledge/GLOSSARY.md\n.ai/knowledge/RULES.md\n" {
		t.Errorf("%q", text(p))
	}
	// A ledger with two of the three, one of them stale.
	h := func(s string) string { return storage.BlobSHA1([]byte(s)) }
	write(t, root, ".ai/workspace/tasks/t1/context",
		h("ARCHITECTURE.md\n")+"\t.ai/knowledge/ARCHITECTURE.md\timplement\n"+
			h("GLOSSARY.md\n")+"\t.ai/knowledge/GLOSSARY.md\n"+
			"deadbeef\t.ai/knowledge/RULES.md\tplan\n")
	if got := text(Context(ctx, append([]string{"pending"}, args...))); got != ".ai/knowledge/RULES.md\n" {
		t.Errorf("pending %q", got)
	}
	write(t, root, ".ai/workspace/tasks/t1/context",
		h("ARCHITECTURE.md\n")+"\t.ai/knowledge/ARCHITECTURE.md\timplement\n"+
			h("GLOSSARY.md\n")+"\t.ai/knowledge/GLOSSARY.md\n"+
			h("RULES.md\n")+"\t.ai/knowledge/RULES.md\timplement\n")
	ok := Context(ctx, append([]string{"guard"}, args...))
	want = "context guard: ok (3 document(s) acknowledged)\n" +
		"  1 acknowledged at no stage\n" +
		"  2 acknowledged at implement\n" +
		"  none acknowledged at plan: this guard passed on acknowledgements made elsewhere\n"
	if ok.Code != 0 || text(ok) != want {
		t.Errorf("%d\n%s", ok.Code, text(ok))
	}
	// Without a task the guard says nothing was checked.
	if got := text(Context(ctx, []string{"guard", "--no-task", "--files", "x"})); got != "context guard: no task workspace; nothing tracked\n" {
		t.Errorf("%q", got)
	}
	if got := text(Context(ctx, []string{"pending", "--no-task", "--files", "x"})); got != "context pending: no task workspace; nothing tracked\n" {
		t.Errorf("%q", got)
	}
}

func TestLinkedLines(t *testing.T) {
	root := progressiveFixture(t)
	other := root + "/../nbr-" + strings.ReplaceAll(t.Name(), "/", "_")
	_ = other
	write(t, root, ".ai/workspace/tasks/t1/task.md", "goal\nLinked: bad\nLinked: nowhere#x1\nLinked: .#t1\nLinked: a b#c\n")
	out := run(t, root, "resolve", "--task", "t1", "--files", "x")
	for _, want := range []string{
		"linked:    bad  unreachable: malformed link: no # between the repository and the id; the form is <repo>#<task-id> or <repo>#spec/<spec-id>\n",
		"linked:    nowhere#x1  unreachable: no repository at " + root + "/nowhere\n",
		"linked:    .#t1  unreachable: this is the task itself\n",
		"unreachable: malformed link: the repository path may not hold whitespace or a backslash;",
	} {
		if !strings.Contains(text(out), want) {
			t.Errorf("missing %q in\n%s", want, text(out))
		}
	}
}

func TestPauseIsHonouredInProcess(t *testing.T) {
	root := progressiveFixture(t)
	write(t, root, ".ai/runtime/queue", "# jig queue 1 — written by `jig queue` only; do not edit by hand\n"+
		"item\ttask:t1\t-\t100\t2\n"+
		"request\ttask:t1\tpause\t2023-11-14T22:13:20Z\tlunch\n"+
		"request\ttask:other\tpause\t2023-11-14T22:13:20Z\n")
	ctx, _ := ctxFor(root, "feat", nil, nil)
	out := Context(ctx, []string{"resolve", "--task", "t1", "--stage", "plan", "--files", "x"})
	want := "paused: t1 (pause requested at 2023-11-14T22:13:20Z: lunch); stage plan not entered\n" +
		"next:      a person asked for this pause; do not start the plan stage, end the session; jig task resume t1 continues the task\n"
	if out.Code != 4 || text(out) != want {
		t.Fatalf("%d %q", out.Code, text(out))
	}
	if got, want := read(root, ".ai/runtime/queue"), "# jig queue 1 — written by `jig queue` only; do not edit by hand\n"+
		"item\ttask:t1\t-\t100\t2\n"+
		"request\ttask:other\tpause\t2023-11-14T22:13:20Z\t\n"; got != want {
		t.Errorf("queue:\n%s", got)
	}
	state := read(root, ".ai/workspace/tasks/t1/state")
	_ = state
	for _, line := range []string{"paused: true\n", "paused_at: " + ctx.Clock.Today() + "\n", "paused_reason: pause requested at 2023-11-14T22:13:20Z: lunch\n"} {
		if !strings.Contains(state, line) {
			t.Errorf("state lacks %q:\n%s", line, state)
		}
	}
	// A task that is paused already is nothing to do: the context is printed.
	write(t, root, ".ai/runtime/queue", "request\ttask:t1\tpause\t2023-11-14T22:13:20Z\n")
	out = Context(ctx, []string{"resolve", "--task", "t1", "--stage", "plan", "--files", "x"})
	if out.Code != 0 || !strings.Contains(text(out), "global:") {
		t.Errorf("%d %q", out.Code, text(out))
	}
	// A task guessed from the branch is not a declared entry into a stage.
	task(t, root, "t1", "status: active", "branch: feat")
	out = Context(ctx, []string{"resolve", "--stage", "plan", "--files", "x"})
	if out.Code != 0 {
		t.Errorf("%d %q", out.Code, text(out))
	}
	_ = proc.Key
}
