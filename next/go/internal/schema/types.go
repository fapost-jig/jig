// Package schema holds the shapes Jig's files and output have, as Go structs,
// and checks what was read against the JSON Schemas generated from them.
//
// The structs are the source: the schemas under next/go/schemas are generated
// from them by a test (schema_test.go), never written by hand. The schemas are
// embedded (see the schemas package) and read files are validated against them.
package schema

import "github.com/fapost-jig/jig/next/go/internal/errs"

// TaskState is a task's state file (tasks/<id>/state): flat `key: value` lines,
// every value a string. A key a version of Jig added later is allowed: the
// schema names the keys the bash implementation writes and lets others by.
type TaskState struct {
	TaskID                string `json:"task_id" jsonschema:"required,minLength=1"`
	Status                string `json:"status" jsonschema:"required,enum=active,enum=ready,enum=consolidated,enum=abandoned,enum=archived"`
	CreatedAt             string `json:"created_at" jsonschema:"required,pattern=^[0-9]{4}-[0-9]{2}-[0-9]{2}$"`
	UpdatedAt             string `json:"updated_at" jsonschema:"required,pattern=^[0-9]{4}-[0-9]{2}-[0-9]{2}$"`
	Class                 string `json:"class,omitempty" jsonschema:"pattern=^T[0-4]$"`
	KnowledgeConsolidated string `json:"knowledge_consolidated,omitempty" jsonschema:"enum=true,enum=false"`
	RouteEvidence         string `json:"route_evidence,omitempty"`
	Branch                string `json:"branch,omitempty"`
	BaseBranch            string `json:"base_branch,omitempty"`
	BaseCommit            string `json:"base_commit,omitempty"`
	PRURL                 string `json:"pr_url,omitempty"`
	PRInto                string `json:"pr_into,omitempty"`
	Autopilot             string `json:"autopilot,omitempty"`
	AutopilotMode         string `json:"autopilot_mode,omitempty"`
	AutopilotRepairs      string `json:"autopilot_repairs,omitempty" jsonschema:"pattern=^[0-9]+$"`
	AutopilotPhase        string `json:"autopilot_phase,omitempty"`
	Gate                  string `json:"gate,omitempty"`
	GateBy                string `json:"gate_by,omitempty"`
	GateDesign            string `json:"gate_design,omitempty"`
	AbsorbedInto          string `json:"absorbed_into,omitempty"`
	AbandonedAt           string `json:"abandoned_at,omitempty"`
	AbandonedReason       string `json:"abandoned_reason,omitempty"`
	ArchivedAt            string `json:"archived_at,omitempty"`
	ArchivedFrom          string `json:"archived_from,omitempty"`
	ArchivedReason        string `json:"archived_reason,omitempty"`
	NotesThrough          string `json:"notes_through,omitempty"`
	Domains               string `json:"domains,omitempty"`
	TriageOf              string `json:"triage_of,omitempty"`
	TriageTask            string `json:"triage_task,omitempty"`
}

// Frontmatter is the frontmatter of a knowledge document (schemas/frontmatter.md).
// A key not listed is allowed. Scalars are strings, lists are lists of strings.
type Frontmatter struct {
	ID         string   `json:"id" jsonschema:"required,pattern=^[a-z0-9-]+$"`
	Type       string   `json:"type" jsonschema:"required,enum=feature,enum=adr,enum=convention,enum=domain,enum=glossary,enum=rule"`
	Status     string   `json:"status" jsonschema:"required,enum=proposed,enum=active,enum=deprecated,enum=superseded,enum=rejected,enum=accepted"`
	Date       string   `json:"date,omitempty" jsonschema:"pattern=^[0-9]{4}-[0-9]{2}-[0-9]{2}$"`
	Summary    string   `json:"summary,omitempty"`
	Domains    []string `json:"domains,omitempty"`
	Topics     []string `json:"topics,omitempty"`
	Load       string   `json:"load,omitempty" jsonschema:"enum=always,enum=domain,enum=matched,enum=stage"`
	Stages     []string `json:"stages,omitempty"`
	Requires   []string `json:"requires,omitempty"`
	Paths      []string `json:"paths,omitempty"`
	Supersedes string   `json:"supersedes,omitempty"`
	ReviewedAt string   `json:"reviewed_at,omitempty" jsonschema:"pattern=^[0-9]{4}-[0-9]{2}-[0-9]{2}$"`
	Source     string   `json:"source,omitempty"`
	SourceHash string   `json:"source_hash,omitempty"`
}

// Envelope is what a `--json` command prints, one line: schemas/json.md, "The
// envelope". Data is present on success, Error instead of it on a refusal.
type Envelope struct {
	Schema      int            `json:"schema" jsonschema:"required,enum=1"`
	Revision    int64          `json:"revision" jsonschema:"required,minimum=0"`
	GeneratedAt string         `json:"generated_at" jsonschema:"required,pattern=^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"`
	Data        any            `json:"data,omitempty"`
	Error       *EnvelopeError `json:"error,omitempty"`
}

// EnvelopeError is the `error` member of an Envelope. The set of codes is
// errs.All(); the generated schema lists them.
type EnvelopeError struct {
	Code    errs.Code `json:"code" jsonschema:"required"`
	Message string    `json:"message" jsonschema:"required"`
}
