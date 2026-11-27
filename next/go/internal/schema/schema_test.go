package schema

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/errs"
	"github.com/invopop/jsonschema"
)

var update = flag.Bool("update", false, "rewrite the committed schemas from the Go structs")

// generated builds each schema from its struct. invopop/jsonschema is used
// here and nowhere else: it stays out of the binary.
func generated(t *testing.T) map[string][]byte {
	t.Helper()
	reflect := func(v any, id string, adjust func(map[string]any)) []byte {
		r := &jsonschema.Reflector{
			DoNotReference:            true,
			AllowAdditionalProperties: true, // a key a later Jig adds is not an error
		}
		s := r.Reflect(v)
		s.ID = jsonschema.ID("jig://schemas/" + id)
		raw, err := json.Marshal(s)
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		if err := json.Unmarshal(raw, &m); err != nil {
			t.Fatal(err)
		}
		if adjust != nil {
			adjust(m)
		}
		out, err := marshalSorted(m)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	return map[string][]byte{
		TaskStateFile:   reflect(&TaskState{}, TaskStateFile, nil),
		FrontmatterFile: reflect(&Frontmatter{}, FrontmatterFile, nil),
		EnvelopeFile: reflect(&Envelope{}, EnvelopeFile, func(m map[string]any) {
			props := m["properties"].(map[string]any)
			// data or error, never both and never neither.
			m["oneOf"] = []any{
				map[string]any{"required": []any{"data"}, "not": map[string]any{"required": []any{"error"}}},
				map[string]any{"required": []any{"error"}, "not": map[string]any{"required": []any{"data"}}},
			}
			code := props["error"].(map[string]any)["properties"].(map[string]any)["code"].(map[string]any)
			var all []any
			for _, c := range errs.All() {
				all = append(all, string(c))
			}
			code["enum"] = all
		}),
	}
}

// marshalSorted is json.MarshalIndent over maps, whose keys encoding/json sorts,
// so the committed file does not depend on a library's property order.
func marshalSorted(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func TestCommittedSchemasAreTheGeneratedOnes(t *testing.T) {
	dir := filepath.Join("..", "..", "schemas")
	for name, want := range generated(t) {
		path := filepath.Join(dir, name)
		if *update {
			if err := os.WriteFile(path, want, 0o644); err != nil {
				t.Fatal(err)
			}
			continue
		}
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%s: %v (go test ./internal/schema -update writes it)", name, err)
		}
		if !bytes.Equal(got, want) {
			t.Errorf("%s is not what the Go structs generate; run: go test ./internal/schema -update", name)
		}
	}
}

func TestTaskState(t *testing.T) {
	ok := map[string]string{
		"task_id": "x", "status": "active", "created_at": "2026-11-26", "updated_at": "2026-11-26",
		"class": "T3", "future_key": "anything",
	}
	if err := ValidateTaskState("state", ok); err != nil {
		t.Errorf("valid state refused: %v", err)
	}
	for name, mut := range map[string]func(map[string]string){
		"no status":      func(m map[string]string) { delete(m, "status") },
		"bad status":     func(m map[string]string) { m["status"] = "done" },
		"bad class":      func(m map[string]string) { m["class"] = "T5" },
		"bad created_at": func(m map[string]string) { m["created_at"] = "yesterday" },
	} {
		m := map[string]string{}
		for k, v := range ok {
			m[k] = v
		}
		mut(m)
		err := ValidateTaskState("state", m)
		if err == nil {
			t.Errorf("%s: accepted", name)
			continue
		}
		if e, isErr := err.(*errs.Error); !isErr || e.Code != errs.Failed {
			t.Errorf("%s: err = %#v", name, err)
		}
	}
}

func TestFrontmatter(t *testing.T) {
	ok := map[string]any{
		"id": "convention-shell", "type": "convention", "status": "active",
		"paths": []any{"scripts/**"}, "extra": "allowed",
	}
	if err := ValidateFrontmatter("doc", ok); err != nil {
		t.Errorf("valid frontmatter refused: %v", err)
	}
	for name, obj := range map[string]map[string]any{
		"no id":         {"type": "adr", "status": "accepted"},
		"bad type":      {"id": "a", "type": "essay", "status": "active"},
		"paths scalar":  {"id": "a", "type": "adr", "status": "accepted", "paths": "x"},
		"paths mapping": {"id": "a", "type": "adr", "status": "accepted", "paths": map[string]any{}},
		"bad id":        {"id": "Not Valid", "type": "adr", "status": "accepted"},
	} {
		if err := ValidateFrontmatter("doc", obj); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestEnvelope(t *testing.T) {
	for _, line := range []string{
		`{"schema":1,"revision":1792079790,"generated_at":"2026-10-15T12:00:00Z","data":{"a":1}}`,
		`{"schema":1,"revision":0,"generated_at":"2026-10-15T12:00:00Z","error":{"code":"usage","message":"task list: invalid status: bogus"}}`,
	} {
		if err := ValidateEnvelope("line", []byte(line)); err != nil {
			t.Errorf("%s: %v", line, err)
		}
	}
	for name, line := range map[string]string{
		"both":         `{"schema":1,"revision":1,"generated_at":"2026-10-15T12:00:00Z","data":{},"error":{"code":"usage","message":"m"}}`,
		"neither":      `{"schema":1,"revision":1,"generated_at":"2026-10-15T12:00:00Z"}`,
		"unknown code": `{"schema":1,"revision":1,"generated_at":"2026-10-15T12:00:00Z","error":{"code":"nope","message":"m"}}`,
		"schema 2":     `{"schema":2,"revision":1,"generated_at":"2026-10-15T12:00:00Z","data":{}}`,
		"bad time":     `{"schema":1,"revision":1,"generated_at":"noon","data":{}}`,
	} {
		if err := ValidateEnvelope("line", []byte(line)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
