// Package errs is the closed set of failure codes of the Jig contract
// (schemas/json.md, "Failure codes") and the error type that carries one.
package errs

import "fmt"

// Code says why a command refused, in a word a program can act on.
type Code string

// The codes below are exactly the rows of the "Failure codes" table of
// schemas/json.md; a test keeps the two equal.
const (
	Usage                 Code = "usage"
	NotARepository        Code = "not-a-repository"
	NotInitialised        Code = "not-initialised"
	StaleRevision         Code = "stale-revision"
	NotFound              Code = "not-found"
	NotPaused             Code = "not-paused"
	AlreadyPaused         Code = "already-paused"
	WrongCheckout         Code = "wrong-checkout"
	StashConflict         Code = "stash-conflict"
	NotClosable           Code = "not-closable"
	AlreadyExists         Code = "already-exists"
	AlreadyFiled          Code = "already-filed"
	GitNotAllowed         Code = "git-not-allowed"
	WriteBusy             Code = "write-busy"
	BranchCheckedOut      Code = "branch-checked-out"
	BranchDiverged        Code = "branch-diverged"
	BranchHasOtherCommits Code = "branch-has-other-commits"
	BaseNotOnOrigin       Code = "base-not-on-origin"
	WriteStillWaits       Code = "write-still-waits"
	TreeInTheWay          Code = "tree-in-the-way"
	CommitRefused         Code = "commit-refused"
	EpicMissing           Code = "epic-missing"
	NotLinkable           Code = "not-linkable"
	NotProposed           Code = "not-proposed"
	NotOnBase             Code = "not-on-base"
	NotOnBranch           Code = "not-on-branch"
	SourceMissing         Code = "source-missing"
	UpgradeBlocked        Code = "upgrade-blocked"
	UnreleasedSource      Code = "unreleased-source"
	UnknownKey            Code = "unknown-key"
	NotLocal              Code = "not-local"
	InvalidValue          Code = "invalid-value"
	SecretKey             Code = "secret-key"
	NotMerged             Code = "not-merged"
	NotOnStaging          Code = "not-on-staging"
	BehindStaging         Code = "behind-staging"
	CarriesStaging        Code = "carries-staging"
	BaseConflict          Code = "base-conflict"
	ShallowClone          Code = "shallow-clone"
	ForgeUnavailable      Code = "forge-unavailable"
	CiRed                 Code = "ci-red"
	CiPending             Code = "ci-pending"
	CiNone                Code = "ci-none"
	NotApproved           Code = "not-approved"
	ReviewRequired        Code = "review-required"
	Conflict              Code = "conflict"
	Draft                 Code = "draft"
	MergeableUnknown      Code = "mergeable-unknown"
	ForgeRefused          Code = "forge-refused"
	NoPullRequest         Code = "no-pull-request"
	PullRequestClosed     Code = "pull-request-closed"
	WrongFlow             Code = "wrong-flow"
	NotReady              Code = "not-ready"
	NotShipped            Code = "not-shipped"
	NotesStale            Code = "notes-stale"
	ReviewerUnknown       Code = "reviewer-unknown"
	AutopilotRunning      Code = "autopilot-running"
	AutopilotStopped      Code = "autopilot-stopped"
	NoGate                Code = "no-gate"
	AlreadyArchived       Code = "already-archived"
	NotArchived           Code = "not-archived"
	WrongStatus           Code = "wrong-status"
	AlreadyClosed         Code = "already-closed"
	ShipRunning           Code = "ship-running"
	GitLevel              Code = "git-level"
	Failed                Code = "failed"
)

// All lists every code, in the order of the contract's table.
func All() []Code {
	return []Code{
		Usage,
		NotARepository,
		NotInitialised,
		StaleRevision,
		NotFound,
		NotPaused,
		AlreadyPaused,
		WrongCheckout,
		StashConflict,
		NotClosable,
		AlreadyExists,
		AlreadyFiled,
		GitNotAllowed,
		WriteBusy,
		BranchCheckedOut,
		BranchDiverged,
		BranchHasOtherCommits,
		BaseNotOnOrigin,
		WriteStillWaits,
		TreeInTheWay,
		CommitRefused,
		EpicMissing,
		NotLinkable,
		NotProposed,
		NotOnBase,
		NotOnBranch,
		SourceMissing,
		UpgradeBlocked,
		UnreleasedSource,
		UnknownKey,
		NotLocal,
		InvalidValue,
		SecretKey,
		NotMerged,
		NotOnStaging,
		BehindStaging,
		CarriesStaging,
		BaseConflict,
		ShallowClone,
		ForgeUnavailable,
		CiRed,
		CiPending,
		CiNone,
		NotApproved,
		ReviewRequired,
		Conflict,
		Draft,
		MergeableUnknown,
		ForgeRefused,
		NoPullRequest,
		PullRequestClosed,
		WrongFlow,
		NotReady,
		NotShipped,
		NotesStale,
		ReviewerUnknown,
		AutopilotRunning,
		AutopilotStopped,
		NoGate,
		AlreadyArchived,
		NotArchived,
		WrongStatus,
		AlreadyClosed,
		ShipRunning,
		GitLevel,
		Failed,
	}
}

// Error is a refusal: a code for a program and a message for a person.
type Error struct {
	Code    Code
	Message string
}

// Error returns the message, which is what the command prints.
func (e *Error) Error() string { return e.Message }

// New makes an Error with a formatted message.
func New(code Code, format string, args ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, args...)}
}
