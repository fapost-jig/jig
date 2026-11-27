package core

// Counterparts of tests/context.t.sh, see context_port_test.go: `jig context
// resolve`, its selection rules, the catalog, linked-source stubs and the
// required-rows cache.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// --- resolve: load policy ---------------------------------------------------------

func TestContext_resolve_load_always_required_with_no_selectors(t *testing.T) {
	c := newCP(t)
	c.doc("features/always.md", "id: feature-always", "type: feature", "status: active", "load: always")
	r := c.run("resolve")
	r.rc(0)
	r.has("required:  .ai/knowledge/features/always.md  (load: always)")
}

func TestContext_resolve_load_domain_matches_domains_selector(t *testing.T) {
	c := newCP(t)
	c.doc("domains/payments/RULES.md", "id: rule-payments", "type: rule", "status: active", "domains: [payments]", "load: domain")
	r := c.run("resolve", "--domains", "payments")
	r.rc(0)
	r.has("required:  .ai/knowledge/domains/payments/RULES.md  (domains: payments)")
	r = c.run("resolve")
	r.rc(0)
	r.lacks("domains/payments/RULES.md")
}

func TestContext_resolve_load_domain_reaches_the_files_it_names_without_a_domain(t *testing.T) {
	c := newCP(t)
	c.doc("domains/knowledge/RULES.md", "id: rule-knowledge", "type: rule", "status: active", "domains: [knowledge]",
		"paths:", `  - "scripts/lib/knowledge.sh"`, "load: domain")
	r := c.run("resolve", "--files", "scripts/lib/knowledge.sh")
	r.rc(0)
	r.has("required:  .ai/knowledge/domains/knowledge/RULES.md  (paths: scripts/lib/knowledge.sh)")
	// Neither the domain nor a named file: not required.
	r = c.run("resolve", "--files", "scripts/lib/other.sh")
	r.rc(0)
	r.lacks("required:  .ai/knowledge/domains/knowledge/RULES.md")
}

func TestContext_resolve_load_domain_without_paths_still_needs_the_domain(t *testing.T) {
	c := newCP(t)
	c.doc("domains/payments/RULES.md", "id: rule-payments", "type: rule", "status: active", "domains: [payments]", "load: domain")
	r := c.run("resolve", "--files", "src/Payments/Charge.php")
	r.rc(0)
	r.lacks("required:  .ai/knowledge/domains/payments/RULES.md")
}

func TestContext_cache_fingerprint_names_the_selection_rule(t *testing.T) {
	c := newCP(t)
	c.newTask("rule-fp")
	r := c.run("resolve", "--task", "rule-fp", "--files", "src/a.php")
	r.rc(0)
	cache := c.read(".ai/workspace/tasks/rule-fp/context-cache")
	first, _, _ := strings.Cut(cache, "\n")
	if !strings.Contains(first, "rule=") {
		t.Errorf("first line of the cache: %q", first)
	}
}

func TestContext_resolve_matched_by_paths_glob(t *testing.T) {
	c := newCP(t)
	c.doc("features/checkout.md", "id: feature-checkout", "type: feature", "status: active", "paths:", `  - "src/Checkout/**"`)
	r := c.run("resolve", "--files", "src/Checkout/Order.php")
	r.rc(0)
	r.has("required:  .ai/knowledge/features/checkout.md  (paths: src/Checkout/**)")
}

func TestContext_resolve_active_and_accepted_still_resolve(t *testing.T) {
	c := newCP(t)
	c.doc("features/active.md", "id: feature-active", "type: feature", "status: active", "load: always")
	c.doc("adr/0001-accepted.md", "id: adr-0001-accepted", "type: adr", "status: accepted", "date: 2026-01-01", "load: always")
	r := c.run("resolve")
	r.rc(0)
	r.has("required:  .ai/knowledge/features/active.md  (load: always)",
		"required:  .ai/knowledge/adr/0001-accepted.md  (load: always)")
}

func TestContext_resolve_matched_by_topics(t *testing.T) {
	c := newCP(t)
	c.doc("features/checkout.md", "id: feature-checkout", "type: feature", "status: active", "topics: [refunds]")
	r := c.run("resolve", "--topics", "refunds")
	r.rc(0)
	r.has("required:  .ai/knowledge/features/checkout.md  (topics: refunds)")
}

// --- resolve: catalog (domain-only match is not required) ----------------------------

func TestContext_resolve_domain_only_match_goes_to_catalog_not_required(t *testing.T) {
	c := newCP(t)
	c.doc("features/checkout.md", "id: feature-checkout", "type: feature", "status: active", "domains: [payments]",
		`summary: "How checkout builds an order."`)
	r := c.run("resolve", "--domains", "payments")
	r.rc(0)
	r.lacks("required:  .ai/knowledge/features/checkout.md")
	r = c.run("resolve", "--domains", "payments", "--catalog")
	r.rc(0)
	r.has("catalog:   .ai/knowledge/features/checkout.md  [feature-checkout] How checkout builds an order.")
}

func TestContext_resolve_catalog_no_summary_shows_placeholder(t *testing.T) {
	c := newCP(t)
	c.doc("features/checkout.md", "id: feature-checkout", "type: feature", "status: active", "domains: [payments]")
	r := c.run("resolve", "--domains", "payments", "--catalog")
	r.rc(0)
	r.has("catalog:   .ai/knowledge/features/checkout.md  [feature-checkout] (no summary)")
}

func TestContext_resolve_without_catalog_flag_prints_no_catalog_line(t *testing.T) {
	c := newCP(t)
	c.doc("features/checkout.md", "id: feature-checkout", "type: feature", "status: active", "domains: [payments]")
	r := c.run("resolve", "--domains", "payments")
	r.rc(0)
	r.lacks("catalog:")
}

// --- resolve: globals, required and workspace labels together -------------------------

func TestContext_resolve_prints_global_required_and_workspace_labels(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.doc("domains/payments/RULES.md", "id: rule-payments", "type: rule", "status: active", "domains: [payments]", "load: always")
	r := c.run("resolve", "--task", "T-1")
	r.rc(0)
	r.has("global:    .ai/knowledge/GLOSSARY.md",
		"required:  .ai/knowledge/domains/payments/RULES.md  (load: always)",
		"workspace: .ai/workspace/tasks/T-1/task.md")
}

// --- resolve: transitive requires -----------------------------------------------------------

func TestContext_resolve_transitive_requires_two_step_chain(t *testing.T) {
	c := newCP(t)
	c.doc("features/a.md", "id: feature-a", "type: feature", "status: active", "load: always", "requires: [feature-b]")
	c.doc("features/b.md", "id: feature-b", "type: feature", "status: active", "requires: [feature-c]")
	c.doc("features/c.md", "id: feature-c", "type: feature", "status: active")
	r := c.run("resolve")
	r.rc(0)
	r.has("required:  .ai/knowledge/features/a.md  (load: always)",
		"required:  .ai/knowledge/features/b.md  (requires: feature-a)",
		"required:  .ai/knowledge/features/c.md  (requires: feature-b)")
}

func TestContext_resolve_requires_unknown_document_is_fatal(t *testing.T) {
	c := newCP(t)
	c.doc("features/a.md", "id: feature-a", "type: feature", "status: active", "load: always", "requires: [feature-ghost]")
	r := c.run("resolve")
	r.rc(1)
	r.has("requires unknown or inactive document:", "run: jig knowledge check")
}

func TestContext_resolve_requires_inactive_document_is_fatal(t *testing.T) {
	c := newCP(t)
	c.doc("features/old.md", "id: feature-old", "type: feature", "status: deprecated")
	c.doc("features/a.md", "id: feature-a", "type: feature", "status: active", "load: always", "requires: [feature-old]")
	r := c.run("resolve")
	r.rc(1)
	r.has("requires unknown or inactive document: feature-old", "run: jig knowledge check")
}

func TestContext_resolve_requires_proposed_document_is_fatal(t *testing.T) {
	c := newCP(t)
	c.doc("features/old.md", "id: feature-old", "type: feature", "status: proposed")
	c.doc("features/a.md", "id: feature-a", "type: feature", "status: active", "load: always", "requires: [feature-old]")
	r := c.run("resolve")
	r.rc(1)
	r.has("requires unknown or inactive document: feature-old", "run: jig knowledge check")
}

// --- resolve: --ids ---------------------------------------------------------------------------

func TestContext_resolve_ids_promotes_catalog_document_to_required(t *testing.T) {
	c := newCP(t)
	c.doc("features/checkout.md", "id: feature-checkout", "type: feature", "status: active", "domains: [payments]")
	r := c.run("resolve", "--ids", "feature-checkout")
	r.rc(0)
	r.has("required:  .ai/knowledge/features/checkout.md  (id: feature-checkout)")
}

func TestContext_resolve_unknown_id_dies(t *testing.T) {
	c := newCP(t)
	r := c.run("resolve", "--ids", "no-such-id")
	r.rc(1)
	r.has("jig: error: context: no active document with id: no-such-id")
}

// --- resolve: linked-source stubs resolve to their source ------------------------------------------

const stubMissing = "jig: error: context: .ai/knowledge/sources/style.md is selected but its source docs/style.md is missing; fix the link or reject the stub"

// stubSetup is ctx_source_stub_setup: docs/style.md and a proposed stub for it,
// the way `jig knowledge new convention style --source docs/style.md --proposed
// --domains stubdomain` leaves them.
func (c *cp) stubSetup() { c.stub("proposed", "") }

// stubAccept is ctx_source_stub_accept: the same stub accepted, status active
// and the source's hash recorded.
func (c *cp) stubAccept() { c.stub("active", "") }

// stub writes the source and its stub; paths is the stub's paths block ("" is
// none), and a source_hash goes with a status of active.
func (c *cp) stub(status, paths string) {
	c.t.Helper()
	c.write("docs/style.md", "# style\n")
	if paths == "" {
		paths = "paths: []"
	}
	hash := ""
	if status == "active" {
		hash = "source_hash: " + storage.BlobSHA1([]byte("# style\n")) + "\n"
	}
	c.write(".ai/knowledge/sources/style.md", "---\nid: convention-style\ntype: convention\nstatus: "+status+
		"\ndomains:\n  - stubdomain\n"+paths+"\nsource: docs/style.md\n"+hash+
		"---\n# <Title of the linked source>\n\nLinked source: [docs/style.md](../../../docs/style.md).\n")
}

func (c *cp) stubSetStatus(status string) {
	c.t.Helper()
	p := ".ai/knowledge/sources/style.md"
	c.write(p, strings.Replace(c.read(p), "status: proposed", "status: "+status, 1))
}

func TestContext_resolve_never_lists_a_proposed_source_stub(t *testing.T) {
	c := newCP(t)
	c.stubSetup()
	r := c.run("resolve", "--no-task", "--catalog", "--domains", "stubdomain", "--files", "-")
	r.rc(0)
	r.lacks(".ai/knowledge/sources/style.md", "docs/style.md")
}

func TestContext_resolve_resolves_a_hand_edited_active_source_stub_to_its_source(t *testing.T) {
	c := newCP(t)
	c.stubSetup()
	c.stubSetStatus("active")
	r := c.run("resolve", "--no-task", "--catalog", "--domains", "stubdomain", "--files", "-")
	r.rc(0)
	r.has("catalog:   docs/style.md  [convention-style] (no summary)")
	r.lacks("sources/style.md")
}

func TestContext_resolve_ids_refuses_a_still_proposed_source_stub(t *testing.T) {
	c := newCP(t)
	c.stubSetup()
	r := c.run("resolve", "--no-task", "--ids", "convention-style", "--files", "-")
	r.rc(1)
	r.has("jig: error: context: no active document with id: convention-style")
}

func TestContext_resolve_ids_selects_an_accepted_source_stub_to_its_source(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	r := c.run("resolve", "--no-task", "--ids", "convention-style", "--files", "-")
	r.rc(0)
	r.has("required:  docs/style.md  (id: convention-style; linked by convention-style)")
}

func TestContext_resolve_required_via_paths_shows_source_with_linked_by(t *testing.T) {
	c := newCP(t)
	c.stub("active", "paths:\n  - \"docs/**\"")
	r := c.run("resolve", "--no-task", "--files", "docs/other.md")
	r.rc(0)
	r.has("required:  docs/style.md  (paths: docs/**; linked by convention-style)")
}

func TestContext_resolve_requires_closure_pulls_in_a_stub_by_its_source(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	c.write(".ai/knowledge/features/needer.md", "---\nid: feature-needer\ntype: feature\nstatus: active\nload: always\nrequires: [convention-style]\n---\nBody.\n")
	r := c.run("resolve", "--no-task", "--files", "-")
	r.rc(0)
	r.has("required:  docs/style.md  (requires: feature-needer; linked by convention-style)")
}

// An ADR stub has no `paths` and `load` defaults to matched: a bare domain match
// keeps it out of required, in the catalog only.
func TestContext_resolve_adr_stub_without_paths_is_catalog_only(t *testing.T) {
	c := newCP(t)
	c.write("docs/adr/0099-thing.md", "# adr\n")
	c.write(".ai/knowledge/sources/thing.md", "---\nid: adr-thing\ntype: adr\nstatus: active\ndomains:\n  - stubdomain\npaths: []\nsource: docs/adr/0099-thing.md\nsource_hash: "+
		storage.BlobSHA1([]byte("# adr\n"))+"\n---\n# Thing\n")
	r := c.run("resolve", "--no-task", "--catalog", "--domains", "stubdomain", "--files", "-")
	r.rc(0)
	r.has("catalog:   docs/adr/0099-thing.md  [adr-thing]")
	r.lacks("required:")
}

// --all bypasses the resolvable-status filter; the source is still resolved for
// every document it lets through, proposed included.
func TestContext_resolve_all_resolves_a_still_proposed_source_stub_in_the_catalog(t *testing.T) {
	c := newCP(t)
	c.stubSetup()
	r := c.run("resolve", "--no-task", "--catalog", "--all", "--domains", "stubdomain", "--files", "-")
	r.rc(0)
	r.has("catalog:   docs/style.md  [convention-style]")
	r.lacks("sources/style.md")
}

func TestContext_resolve_all_lets_ids_select_a_still_proposed_source_stub_to_its_source(t *testing.T) {
	c := newCP(t)
	c.stubSetup()
	r := c.run("resolve", "--no-task", "--ids", "convention-style", "--all", "--files", "-")
	r.rc(0)
	r.has("required:  docs/style.md  (id: convention-style; linked by convention-style)")
}

func TestContext_stateless_resolves_an_active_source_stub_to_its_source_in_matched(t *testing.T) {
	c := newCP(t)
	c.stubSetup()
	r := c.run("--no-task", "--domains", "stubdomain", "--files", "-")
	r.rc(0)
	r.lacks("docs/style.md")
	c.stubSetStatus("active")
	r = c.run("--no-task", "--domains", "stubdomain", "--files", "-")
	r.rc(0)
	r.has("matched:   docs/style.md  (domains: stubdomain; linked by convention-style)")
	r.lacks("sources/style.md")
}

func TestContext_stateless_format_paths_shows_the_source_path(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	r := c.run("--no-task", "--domains", "stubdomain", "--files", "-", "--format", "paths")
	r.rc(0)
	r.has("docs/style.md")
	r.lacks("sources/style.md")
}

// --- resolve: a linked-source stub whose source is missing ---------------------------------------

func TestContext_resolve_catalog_shows_missing_source(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	removeFile(t, c.root, "docs/style.md")
	r := c.run("resolve", "--no-task", "--catalog", "--domains", "stubdomain", "--files", "-")
	r.rc(0)
	r.has("catalog:   .ai/knowledge/sources/style.md  [convention-style] missing source: docs/style.md")
}

func TestContext_resolve_does_not_die_when_an_unselected_stub_source_is_missing(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	removeFile(t, c.root, "docs/style.md")
	r := c.run("resolve", "--no-task", "--files", "-")
	r.rc(0)
	r.lacks("docs/style.md")
}

func TestContext_resolve_ids_dies_when_the_selected_stub_source_is_missing(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	removeFile(t, c.root, "docs/style.md")
	r := c.run("resolve", "--no-task", "--ids", "convention-style", "--files", "-")
	r.rc(1)
	r.has(stubMissing)
}

func TestContext_resolve_required_via_paths_dies_when_the_selected_stub_source_is_missing(t *testing.T) {
	c := newCP(t)
	c.stub("active", "paths:\n  - \"docs/**\"")
	removeFile(t, c.root, "docs/style.md")
	r := c.run("resolve", "--no-task", "--files", "docs/other.md")
	r.rc(1)
	r.has(stubMissing)
}

func TestContext_stateless_dies_when_a_matched_stub_source_is_missing(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	removeFile(t, c.root, "docs/style.md")
	r := c.run("--no-task", "--domains", "stubdomain", "--files", "-")
	r.rc(1)
	r.has(stubMissing)
}

// --- required-rows cache: resolve / guard / pending agree without recomputing -------------------------

func TestContext_guard_reuses_resolves_required_set_unchanged(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.doc("features/checkout.md", "id: feature-checkout", "type: feature", "status: active", "load: always")
	r := c.run("resolve", "--task", "T-1")
	r.rc(0)
	r.has("required:  .ai/knowledge/features/checkout.md  (load: always)")
	// A cache file now exists for this task and the same selectors; guard must
	// report the same four documents resolve just did.
	if c.read(".ai/workspace/tasks/T-1/context-cache") == "" {
		t.Fatal("no context-cache")
	}
	r = c.run("guard", "--task", "T-1")
	r.rc(1)
	r.has("context guard: 4 of 4 document(s) not acknowledged:", "  .ai/knowledge/features/checkout.md")
}

func TestContext_cache_is_invalidated_when_a_documents_selection_changes(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	c.doc("features/extra.md", "id: feature-extra", "type: feature", "status: active", "paths:", `  - "does/not/exist/**"`)
	r := c.run("resolve", "--task", "T-1")
	r.rc(0)
	r.lacks("extra.md")
	// The document now matches by `load: always`; the very next resolve shows it.
	c.doc("features/extra.md", "id: feature-extra", "type: feature", "status: active", "load: always")
	r = c.run("resolve", "--task", "T-1")
	r.rc(0)
	r.has("required:  .ai/knowledge/features/extra.md  (load: always)")
}

func TestContext_cache_is_invalidated_when_a_document_is_added(t *testing.T) {
	c := newCP(t)
	c.newTask("T-1")
	r := c.run("resolve", "--task", "T-1")
	r.rc(0)
	r.lacks("added.md")
	c.doc("features/added.md", "id: feature-added", "type: feature", "status: active", "load: always")
	r = c.run("resolve", "--task", "T-1")
	r.rc(0)
	r.has("required:  .ai/knowledge/features/added.md  (load: always)")
}

// --- symlinked sources ---------------------------------------------------------------------------------

func symlinkOrSkip(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("symbolic links cannot be made here: %v", err)
	}
}

// outsideFile is a file outside the project, the /etc/hosts of the bash tests.
func outsideFile(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "hosts")
	if err := os.WriteFile(p, []byte("127.0.0.1 localhost\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestContext_resolve_treats_a_source_swapped_for_a_symlink_as_missing(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	removeFile(t, c.root, "docs/style.md")
	symlinkOrSkip(t, outsideFile(t), filepath.Join(c.root, "docs/style.md"))
	r := c.run("resolve", "--no-task", "--catalog", "--domains", "stubdomain", "--files", "-")
	r.rc(0)
	r.has("[convention-style] missing source: docs/style.md")
	r = c.run("resolve", "--no-task", "--ids", "convention-style", "--files", "-")
	r.rc(1)
	r.has("is selected but its source docs/style.md is missing")
}

func TestContext_resolve_treats_a_source_under_a_symlinked_directory_as_missing(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "style.md"), []byte("# style\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(filepath.Join(c.root, "docs")); err != nil {
		t.Fatal(err)
	}
	symlinkOrSkip(t, outside, filepath.Join(c.root, "docs"))
	r := c.run("resolve", "--no-task", "--ids", "convention-style", "--files", "-")
	r.rc(1)
	r.has("is selected but its source docs/style.md is missing")
}

func TestContext_resolve_follows_a_source_under_a_directory_symlinked_inside_the_repository(t *testing.T) {
	c := newCP(t)
	c.stubAccept()
	if err := os.MkdirAll(filepath.Join(c.root, "real"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(c.root, "docs/style.md"), filepath.Join(c.root, "real/style.md")); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(filepath.Join(c.root, "docs")); err != nil {
		t.Fatal(err)
	}
	symlinkOrSkip(t, "real", filepath.Join(c.root, "docs"))
	r := c.run("resolve", "--no-task", "--ids", "convention-style", "--files", "-")
	r.rc(0)
	r.has("docs/style.md")
	r.lacks("missing")
	r = c.run("resolve", "--no-task", "--catalog", "--domains", "stubdomain", "--files", "-")
	r.rc(0)
	r.has("catalog:   docs/style.md  [convention-style] (no summary)")
}

func TestContext_stateless_all_resolves_a_proposed_stub_to_its_source(t *testing.T) {
	c := newCP(t)
	c.stubSetup()
	r := c.run("--no-task", "--all", "--domains", "stubdomain", "--files", "-")
	r.rc(0)
	r.has("matched:   docs/style.md  (domains: stubdomain; linked by convention-style)")
}
