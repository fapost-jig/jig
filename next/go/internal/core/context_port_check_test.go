package core

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// contextShCounterpartExceptions are the bash tests of tests/context.t.sh with no
// Go test of their own name, each with the reason. A test only about bash itself
// (process counts, bash 3.2 quirks) goes here; none of the current ones is.
var contextShCounterpartExceptions = map[string]string{}

// contextGoName is the rule that names the Go counterpart of a bash test:
// test_<area>_<rest> is Test<Area>_<rest>, so test_context_files_exact_match is
// TestContext_files_exact_match and test_sdd_stage_x is TestSdd_stage_x.
func contextGoName(bash string) string {
	rest := strings.TrimPrefix(bash, "test_")
	area, tail, ok := strings.Cut(rest, "_")
	if !ok || area == "" {
		return "Test" + rest
	}
	return "Test" + strings.ToUpper(area[:1]) + area[1:] + "_" + tail
}

// TestEveryContextShTestHasACounterpart keeps the Go suite a stand-in for
// tests/context.t.sh: a bash test added there without a Go test of the name
// contextGoName gives (or an entry in contextShCounterpartExceptions) fails here.
func TestEveryContextShTestHasACounterpart(t *testing.T) {
	src, err := os.ReadFile("../../../../tests/context.t.sh")
	if err != nil {
		t.Skip("tests/context.t.sh is not part of this checkout")
	}
	var bash []string
	for _, m := range regexp.MustCompile(`(?m)^(test_[A-Za-z0-9_]+)\(\)`).FindAllStringSubmatch(string(src), -1) {
		bash = append(bash, m[1])
	}
	if len(bash) == 0 {
		t.Fatal("no test_* function found in tests/context.t.sh")
	}

	goTests := map[string]bool{}
	files, _ := filepath.Glob("*_test.go")
	decl := regexp.MustCompile(`(?m)^func (Test[A-Za-z0-9_]+)\(`)
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range decl.FindAllStringSubmatch(string(data), -1) {
			goTests[m[1]] = true
		}
	}

	var missing []string
	seen := map[string]string{}
	for _, name := range bash {
		g := contextGoName(name)
		if prev, dup := seen[g]; dup {
			t.Errorf("%s and %s map to the same Go name %s", prev, name, g)
		}
		seen[g] = name
		if reason, ok := contextShCounterpartExceptions[name]; ok {
			if reason == "" {
				t.Errorf("the exception for %s gives no reason", name)
			}
			continue
		}
		if !goTests[g] {
			missing = append(missing, name+" (want "+g+")")
		}
	}
	sort.Strings(missing)
	for _, m := range missing {
		t.Errorf("no Go counterpart for %s", m)
	}
	for name := range contextShCounterpartExceptions {
		found := false
		for _, b := range bash {
			found = found || b == name
		}
		if !found {
			t.Errorf("the exception %s names no test of tests/context.t.sh", name)
		}
	}
}
