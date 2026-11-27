package errs

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// repoRoot walks up from the package directory to the Jig repository root.
func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "schemas", "json.md")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("schemas/json.md not found above " + dir)
		}
		dir = parent
	}
}

// contractCodes reads the codes of the "Failure codes" table of schemas/json.md.
func contractCodes(t *testing.T) []string {
	t.Helper()
	f, err := os.Open(filepath.Join(repoRoot(t), "schemas", "json.md"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	row := regexp.MustCompile("^\\| `([a-z-]+)` \\|")
	var codes []string
	in := false
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "## "):
			in = line == "## Failure codes"
		case in:
			if m := row.FindStringSubmatch(line); m != nil && m[1] != "code" {
				codes = append(codes, m[1])
			}
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	return codes
}

func TestCodesAreTheContractsCodes(t *testing.T) {
	want := contractCodes(t)
	if len(want) < 10 {
		t.Fatalf("parsed only %d codes from schemas/json.md", len(want))
	}
	var got []string
	for _, c := range All() {
		got = append(got, string(c))
	}
	sort.Strings(want)
	sort.Strings(got)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("errs.All() and the table in schemas/json.md differ\n go:    %v\n table: %v", got, want)
	}
	found := false
	for _, c := range got {
		if c == string(Failed) {
			found = true
		}
	}
	if !found {
		t.Error("the table has no `failed` code")
	}
}

func TestErrorCarriesCodeAndMessage(t *testing.T) {
	var err error = New(Usage, "unknown command: %s", "x")
	if err.Error() != "unknown command: x" {
		t.Errorf("Error() = %q", err.Error())
	}
	if err.(*Error).Code != Usage {
		t.Errorf("code = %q", err.(*Error).Code)
	}
}
