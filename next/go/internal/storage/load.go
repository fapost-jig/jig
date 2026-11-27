package storage

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/fapost-jig/jig/next/go/internal/errs"
	"github.com/fapost-jig/jig/next/go/internal/schema"
)

// LoadTaskState reads task id's state file, checks it against the task-state
// schema and decodes it. A task with no state is errs.NotFound; a file that
// does not fit the schema is `failed`, as the contract has no code for it yet.
func LoadTaskState(root, id string) (schema.TaskState, error) {
	var st schema.TaskState
	text, err := ReadTaskState(root, id)
	switch {
	case errors.Is(err, ErrInvalidID):
		return st, errs.New(errs.Usage, "invalid task id: %s", id)
	case IsNotExist(err):
		return st, errs.New(errs.NotFound, "no such task: %s", id)
	case err != nil:
		return st, errs.New(errs.Failed, "task %s: %v", id, err)
	}
	_, values := StateKeys(text)
	what := fmt.Sprintf("task %s: state", id)
	if err := schema.ValidateTaskState(what, values); err != nil {
		return st, err
	}
	raw, err := json.Marshal(values)
	if err != nil {
		return st, errs.New(errs.Failed, "%s: %v", what, err)
	}
	if err := json.Unmarshal(raw, &st); err != nil {
		return st, errs.New(errs.Failed, "%s: %v", what, err)
	}
	return st, nil
}

// LoadFrontmatter reads the frontmatter of the knowledge document at path,
// checks it against the frontmatter schema and decodes it. has is false when the
// document has no frontmatter; a frontmatter that is not flat YAML or does not
// fit the schema is `failed`.
func LoadFrontmatter(path string) (fm schema.Frontmatter, has bool, err error) {
	doc, has, err := ReadFrontmatter(path)
	if err != nil {
		if IsNotExist(err) {
			return fm, false, errs.New(errs.NotFound, "no such document: %s", path)
		}
		return fm, has, errs.New(errs.Failed, "%v", err)
	}
	if !has {
		return fm, false, nil
	}
	obj := doc.Object()
	what := path + ": frontmatter"
	if err := schema.ValidateFrontmatter(what, obj); err != nil {
		return fm, true, err
	}
	raw, err := json.Marshal(obj)
	if err != nil {
		return fm, true, errs.New(errs.Failed, "%s: %v", what, err)
	}
	if err := json.Unmarshal(raw, &fm); err != nil {
		return fm, true, errs.New(errs.Failed, "%s: %v", what, err)
	}
	return fm, true, nil
}
