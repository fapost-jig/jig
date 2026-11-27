package core

// Counterparts of tests/context.t.sh, see context_port_test.go: stage-aware
// resolution (the sdd_* tests), `load: stage` documents (stage_only_*) and the
// catalog of project-wide documents.

import (
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// sddSetup is sdd_stage_setup.
func (c *cp) sddSetup() {
	c.newTask("stage-task", "class: T3", "domains: payments")
	c.write(".ai/knowledge/features/staged.md", "---\nid: feature-staged\ntype: feature\nstatus: active\ndomains: [payments]\nload: matched\n"+
		"stages: [implement]\nsummary: Implementation guidance.\nrequires: [feature-dependency]\n---\nStage body.\n")
	c.write(".ai/knowledge/features/dependency.md", "---\nid: feature-dependency\ntype: feature\nstatus: active\ndomains: [other]\n"+
		"summary: Dependency.\n---\nDependency body.\n")
}

func (c *cp) ackGlobals(task string) {
	for _, g := range []string{"GLOSSARY", "ARCHITECTURE", "RULES"} {
		c.run("acknowledge", "--task", task, "--files", ".ai/knowledge/"+g+".md")
	}
}

func TestSdd_stage_promotes_only_entered_catalog_and_closes_requires(t *testing.T) {
	c := newCP(t)
	c.sddSetup()
	r := c.run("resolve", "--task", "stage-task", "--stage", "implement", "--files", "-")
	r.rc(0)
	r.has("stage: implement; domain: payments", "requires: feature-staged")
	r = c.run("resolve", "--task", "stage-task", "--stage", "design", "--files", "-")
	r.rc(0)
	r.lacks("features/staged.md")
	r = c.run("resolve", "--no-task", "--stage", "implement", "--domains", "other", "--files", "-")
	r.rc(0)
	r.lacks("features/staged.md")
	r = c.run("resolve", "--no-task", "--stage", "implement", "--files", "-")
	r.lacks("features/staged.md")
}

func TestSdd_requires_closure_brings_a_stage_only_document_at_any_stage(t *testing.T) {
	c := newCP(t)
	c.sddSetup()
	c.write(".ai/knowledge/features/consolidation-only.md", "---\nid: feature-consolidation-only\ntype: feature\nstatus: active\n"+
		"domains: []\npaths: []\nload: stage\nstages: [consolidate]\nsummary: Consolidation-only guidance.\n---\nConsolidation body.\n")
	// The matched document requires a document that is stage-only at consolidate.
	p := ".ai/knowledge/features/staged.md"
	c.write(p, strings.Replace(c.read(p), "requires: [feature-dependency]", "requires: [feature-dependency, feature-consolidation-only]", 1))
	r := c.run("resolve", "--task", "stage-task", "--stage", "implement", "--files", "-")
	r.rc(0)
	r.has("features/consolidation-only.md", "requires: feature-staged")
}

func TestSdd_stage_never_hides_path_topic_always_domain_or_explicit_ids(t *testing.T) {
	c := newCP(t)
	c.sddSetup()
	c.write(".ai/knowledge/features/binding.md", "---\nid: feature-binding\ntype: feature\nstatus: active\npaths: [bound.txt]\ntopics: [money]\nstages: [verify]\n---\nBinding.\n")
	r := c.run("resolve", "--task", "stage-task", "--stage", "design", "--files", "bound.txt")
	r.rc(0)
	r.has("paths: bound.txt")
	r = c.run("resolve", "--task", "stage-task", "--stage", "design", "--topics", "money", "--files", "-")
	r.has("topics: money")
	r = c.run("resolve", "--task", "stage-task", "--stage", "design", "--ids", "feature-staged", "--files", "-")
	r.has("id: feature-staged")
	c.write(".ai/knowledge/features/always.md", "---\nid: feature-always\ntype: feature\nstatus: active\nload: always\nstages: [verify]\n---\nAlways.\n")
	c.write(".ai/knowledge/features/domain.md", "---\nid: feature-domain\ntype: feature\nstatus: active\nload: domain\ndomains: [payments]\nstages: [verify]\n---\nDomain.\n")
	r = c.run("resolve", "--task", "stage-task", "--stage", "design", "--files", "-")
	r.has("load: always", "features/domain.md")
}

func TestSdd_stage_change_uses_hash_ledger_without_rereading_unchanged(t *testing.T) {
	c := newCP(t)
	c.sddSetup()
	c.ackGlobals("stage-task")
	c.run("guard", "--task", "stage-task", "--stage", "design", "--files", "-").rc(0)
	r := c.run("guard", "--task", "stage-task", "--stage", "implement", "--files", "-")
	r.rc(1)
	r.has("features/staged.md")
	c.run("acknowledge", "--task", "stage-task", "--files", ".ai/knowledge/features/staged.md,.ai/knowledge/features/dependency.md")
	c.run("guard", "--task", "stage-task", "--stage", "implement", "--files", "-").rc(0)
	c.write(".ai/knowledge/features/staged.md", c.read(".ai/knowledge/features/staged.md")+"changed\n")
	r = c.run("pending", "--task", "stage-task", "--stage", "implement", "--files", "-")
	r.is(".ai/knowledge/features/staged.md")
}

func TestSdd_stage_missing_dependencies_and_globals_fail_even_taskless(t *testing.T) {
	c := newCP(t)
	c.sddSetup()
	removeFile(t, c.root, ".ai/knowledge/features/dependency.md")
	for _, sub := range []string{"resolve", "pending", "guard"} {
		r := c.run(sub, "--no-task", "--stage", "implement", "--domains", "payments", "--files", "-")
		r.rc(1)
		r.has("requires unknown or inactive")
		r = c.run(sub, "--no-task", "--ids", "no-such-id", "--files", "-")
		r.rc(1)
		r.has("no active document")
	}
	removeFile(t, c.root, ".ai/knowledge/RULES.md")
	for _, sub := range []string{"resolve", "pending", "guard"} {
		r := c.run(sub, "--no-task", "--files", "-")
		r.rc(1)
		r.has("missing or unreadable mandatory global")
	}
}

func TestSdd_stage_excludes_proposed_and_rejected(t *testing.T) {
	c := newCP(t)
	c.sddSetup()
	p := ".ai/knowledge/features/staged.md"
	c.write(p, strings.Replace(c.read(p), "status: active", "status: proposed", 1))
	r := c.run("resolve", "--task", "stage-task", "--stage", "implement", "--catalog", "--files", "-")
	r.rc(0)
	r.lacks("features/staged.md")
	// jig knowledge reject feature-staged
	c.write(p, strings.Replace(c.read(p), "status: proposed", "status: rejected", 1))
	r = c.run("resolve", "--task", "stage-task", "--stage", "implement", "--catalog", "--files", "-")
	r.rc(0)
	r.lacks("features/staged.md")
}

func TestSdd_taskless_research_bypasses_ambiguous_and_single_task(t *testing.T) {
	c := newCP(t)
	c.sddSetup()
	before := c.read(".ai/workspace/tasks/stage-task/state")
	r := c.run("resolve", "--no-task", "--stage", "implement", "--files", "-")
	r.rc(0)
	r.lacks("workspace:", "features/staged.md")
	c.newTask("another")
	r = c.run("resolve", "--no-task", "--files", "-")
	r.rc(0)
	r.lacks("multiple", "stage-task")
	r = c.run("--no-task", "--files", "-")
	r.rc(0)
	r.lacks("workspace:")
	r = c.run("guard", "--no-task", "--files", "-")
	r.has("no task workspace; nothing tracked")
	eq(t, before, c.read(".ai/workspace/tasks/stage-task/state"))
}

func TestSdd_stage_and_taskless_argument_validation(t *testing.T) {
	c := newCP(t)
	c.sddSetup()
	r := c.run("resolve", "--stage", "nonsense")
	r.rc(1)
	r.has("invalid stage")
	r = c.run("resolve", "--stage")
	r.rc(1)
	r.has("requires a value")
	r = c.run("--stage", "implement")
	r.rc(1)
	r.has("use jig context resolve")
	r = c.run("resolve", "--no-task", "--task", "stage-task")
	r.rc(1)
	r.has("conflicts")
	r = c.run("--task", "stage-task", "--no-task")
	r.rc(1)
	r.has("conflicts")
}

// --- load: stage — required at its stage and nowhere else --------------------------------

// stageOnlySetup is stage_only_setup.
func (c *cp) stageOnlySetup() {
	c.newTask("so-task", "class: T3", "domains: payments")
	c.write(".ai/knowledge/conventions/published-docs.md", "---\nid: convention-published-docs-updates\ntype: convention\nstatus: active\n"+
		"domains: []\npaths: []\nload: stage\nstages: [consolidate]\nsummary: Published docs follow the release.\n---\nBody.\n")
}

func TestStage_only_required_at_its_stage_with_task(t *testing.T) {
	c := newCP(t)
	c.stageOnlySetup()
	r := c.run("resolve", "--task", "so-task", "--stage", "consolidate", "--files", "-")
	r.rc(0)
	r.has("load: stage; stage: consolidate", ".ai/knowledge/conventions/published-docs.md")
}

func TestStage_only_absent_elsewhere_even_from_catalog(t *testing.T) {
	c := newCP(t)
	c.stageOnlySetup()
	r := c.run("resolve", "--task", "so-task", "--stage", "implement", "--catalog", "--files", "-")
	r.rc(0)
	r.lacks("published-docs.md")
	r = c.run("resolve", "--task", "so-task", "--catalog", "--files", "-")
	r.lacks("published-docs.md")
}

func TestStage_only_required_without_a_task(t *testing.T) {
	c := newCP(t)
	c.stageOnlySetup()
	r := c.run("resolve", "--no-task", "--stage", "consolidate", "--files", "-")
	r.rc(0)
	r.has("published-docs.md")
}

func TestStage_only_ignores_paths_domains_and_topics(t *testing.T) {
	c := newCP(t)
	c.stageOnlySetup()
	c.write(".ai/knowledge/conventions/bound.md", "---\nid: convention-bound\ntype: convention\nstatus: active\ndomains: [payments]\n"+
		"paths: [bound.txt]\ntopics: [money]\nload: stage\nstages: [verify]\n---\nBound.\n")
	r := c.run("resolve", "--task", "so-task", "--stage", "design", "--files", "bound.txt", "--topics", "money")
	r.rc(0)
	r.lacks("conventions/bound.md")
	r = c.run("resolve", "--task", "so-task", "--stage", "verify", "--files", "-")
	r.has("conventions/bound.md")
}

func TestStage_only_guard_fails_until_acknowledged(t *testing.T) {
	c := newCP(t)
	c.stageOnlySetup()
	c.ackGlobals("so-task")
	r := c.run("guard", "--task", "so-task", "--stage", "consolidate", "--files", "-")
	r.rc(1)
	r.has("published-docs.md")
	c.run("acknowledge", "--task", "so-task", "--files", ".ai/knowledge/conventions/published-docs.md")
	c.run("guard", "--task", "so-task", "--stage", "consolidate", "--files", "-").rc(0)
}

func TestStage_only_ids_still_select_it(t *testing.T) {
	c := newCP(t)
	c.stageOnlySetup()
	r := c.run("resolve", "--task", "so-task", "--stage", "implement", "--ids", "convention-published-docs-updates", "--files", "-")
	r.rc(0)
	r.has("id: convention-published-docs-updates")
}

func TestStage_only_stateless_form_never_lists_it(t *testing.T) {
	c := newCP(t)
	c.stageOnlySetup()
	c.write(".ai/knowledge/conventions/bound.md", "---\nid: convention-bound\ntype: convention\nstatus: active\ndomains: [payments]\n"+
		"paths: [bound.txt]\nload: stage\nstages: [verify]\n---\nBound.\n")
	r := c.run("--files", "bound.txt", "--domains", "payments")
	r.rc(0)
	r.lacks("conventions/bound.md")
}

func TestStage_only_survives_the_resolution_cache(t *testing.T) {
	c := newCP(t)
	c.stageOnlySetup()
	r := c.run("resolve", "--task", "so-task", "--stage", "consolidate", "--files", "-")
	r.has("published-docs.md")
	r = c.run("resolve", "--task", "so-task", "--stage", "consolidate", "--files", "-")
	r.rc(0)
	r.has("published-docs.md")
}

// --- resolve: catalog lists project-wide documents -----------------------------------------------
// A document with neither `domains` nor `paths` belongs to no domain an agent can
// enter and matches no file it can touch; the catalog is the one place it can be seen.

func TestContext_resolve_catalog_lists_a_project_wide_document_without_domains(t *testing.T) {
	c := newCP(t)
	c.doc("conventions/team.md", "id: convention-team", "type: convention", "status: active", `summary: "How the team writes code."`)
	r := c.run("resolve", "--no-task", "--catalog", "--files", "-")
	r.rc(0)
	r.has("catalog:   .ai/knowledge/conventions/team.md  [convention-team] How the team writes code.")
	r.lacks("required:  .ai/knowledge/conventions/team.md")
	r = c.run("resolve", "--domains", "payments", "--catalog")
	r.has("catalog:   .ai/knowledge/conventions/team.md  [convention-team]")
}

func TestContext_resolve_catalog_skips_a_document_with_paths_but_no_domains(t *testing.T) {
	c := newCP(t)
	c.doc("conventions/api.md", "id: convention-api", "type: convention", "status: active", "paths:", `  - "src/api/**"`)
	r := c.run("resolve", "--no-task", "--catalog", "--files", "-")
	r.lacks("convention-api")
}

func TestContext_resolve_catalog_never_lists_a_proposed_project_wide_document(t *testing.T) {
	c := newCP(t)
	c.doc("conventions/team.md", "id: convention-team", "type: convention", "status: proposed")
	r := c.run("resolve", "--no-task", "--catalog", "--files", "-")
	r.lacks("convention-team")
}

func TestContext_resolve_accepted_linked_team_adr_without_domains_is_in_the_catalog(t *testing.T) {
	c := newCP(t)
	c.write("docs/adr/0001-team.md", "# adr\n")
	c.write(".ai/knowledge/sources/0001-team.md", "---\nid: adr-0001-team\ntype: adr\nstatus: active\ndomains: []\npaths: []\nsource: docs/adr/0001-team.md\nsource_hash: "+
		storage.BlobSHA1([]byte("# adr\n"))+"\n---\n# Team\n")
	r := c.run("resolve", "--no-task", "--catalog", "--files", "-")
	r.rc(0)
	r.has("catalog:   docs/adr/0001-team.md  [adr-0001-team]")
}
