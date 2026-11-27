package schema

import (
	"bytes"
	"fmt"
	"sync"

	"github.com/fapost-jig/jig/next/go/internal/errs"
	"github.com/fapost-jig/jig/next/go/schemas"
	jsonschema "github.com/santhosh-tekuri/jsonschema/v6"
)

// File names of the committed schemas.
const (
	TaskStateFile   = "task-state.schema.json"
	FrontmatterFile = "frontmatter.schema.json"
	EnvelopeFile    = "envelope.schema.json"
)

var (
	mu       sync.Mutex
	compiled = map[string]*jsonschema.Schema{}
)

// compile reads the embedded schema file and compiles it once.
func compile(file string) (*jsonschema.Schema, error) {
	mu.Lock()
	defer mu.Unlock()
	if s, ok := compiled[file]; ok {
		return s, nil
	}
	raw, err := schemas.FS.ReadFile(file)
	if err != nil {
		return nil, errs.New(errs.Failed, "schema %s: %v", file, err)
	}
	doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(raw))
	if err != nil {
		return nil, errs.New(errs.Failed, "schema %s: %v", file, err)
	}
	url := "jig://schemas/" + file
	c := jsonschema.NewCompiler()
	if err := c.AddResource(url, doc); err != nil {
		return nil, errs.New(errs.Failed, "schema %s: %v", file, err)
	}
	s, err := c.Compile(url)
	if err != nil {
		return nil, errs.New(errs.Failed, "schema %s: %v", file, err)
	}
	compiled[file] = s
	return s, nil
}

// validate checks instance (decoded JSON: map[string]any, []any, string, …)
// against the embedded schema file. A refusal is a `failed` error naming what
// was read: the contract has no code for an invalid file yet.
func validate(file, what string, instance any) error {
	s, err := compile(file)
	if err != nil {
		return err
	}
	if err := s.Validate(instance); err != nil {
		return errs.New(errs.Failed, "%s: %s", what, firstLine(err))
	}
	return nil
}

func firstLine(err error) string {
	msg := fmt.Sprintf("%v", err)
	for i := 0; i < len(msg); i++ {
		if msg[i] == '\n' {
			return msg[:i]
		}
	}
	return msg
}

// ValidateTaskState checks the keys and values read from a task's state file.
func ValidateTaskState(what string, values map[string]string) error {
	obj := make(map[string]any, len(values))
	for k, v := range values {
		obj[k] = v
	}
	return validate(TaskStateFile, what, obj)
}

// ValidateFrontmatter checks the object of a document's frontmatter, as
// storage.Doc.Object gives it.
func ValidateFrontmatter(what string, obj map[string]any) error {
	return validate(FrontmatterFile, what, obj)
}

// ValidateEnvelope checks one line of `--json` output.
func ValidateEnvelope(what string, line []byte) error {
	doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(line))
	if err != nil {
		return errs.New(errs.Failed, "%s: %v", what, err)
	}
	return validate(EnvelopeFile, what, doc)
}
