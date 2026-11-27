package archtest

import (
	"bytes"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

const modulePath = "github.com/fapost-jig/jig/next/go"

// moduleRoot is the directory with go.mod, above the package.
func moduleRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("go.mod not found above the package")
		}
		dir = parent
	}
}

// source is one parsed non-test file of the module.
type source struct {
	rel  string // slash path from the module root
	pkg  string // directory of the file, slash path from the module root
	file *ast.File
	fset *token.FileSet
}

// sources parses every .go file of the module that is not a _test.go file.
func sources(t *testing.T) []source {
	t.Helper()
	root := moduleRoot(t)
	var out []source
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if name := d.Name(); name == ".build" || name == "testdata" || strings.HasPrefix(name, ".") && path != root {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		fset := token.NewFileSet()
		f, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		rel = filepath.ToSlash(rel)
		out = append(out, source{rel: rel, pkg: filepath.ToSlash(filepath.Dir(rel)), file: f, fset: fset})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(out) < 10 {
		t.Fatalf("only %d source files found: the walk is wrong", len(out))
	}
	return out
}

func imports(s source) map[string]string { // import path -> local name
	m := map[string]string{}
	for _, im := range s.file.Imports {
		p, _ := strconv.Unquote(im.Path.Value)
		name := filepath.Base(p)
		if im.Name != nil {
			name = im.Name.Name
		}
		m[p] = name
	}
	return m
}

func TestOnlyProcImportsOsExec(t *testing.T) {
	for _, s := range sources(t) {
		if _, ok := imports(s)["os/exec"]; ok && s.pkg != "internal/proc" {
			t.Errorf("%s imports os/exec; only internal/proc starts processes", s.rel)
		}
	}
}

func TestPackagesImportOnlyWhatTheirLayerMay(t *testing.T) {
	cli := modulePath + "/internal/cli"
	core := modulePath + "/internal/core"
	for _, s := range sources(t) {
		for p := range imports(s) {
			switch s.pkg {
			case "internal/core":
				if p == cli {
					t.Errorf("%s: core imports cli", s.rel)
				}
			case "internal/storage", "internal/proc", "internal/clock", "internal/errs", "internal/schema", "schemas":
				if p == cli || p == core {
					t.Errorf("%s: %s imports %s", s.rel, s.pkg, p)
				}
			}
		}
	}
}

// fsFunctions are the functions of os that read or change the file system.
var osFS = map[string]bool{
	"ReadFile": true, "WriteFile": true, "Open": true, "OpenFile": true, "Create": true,
	"CreateTemp": true, "Remove": true, "RemoveAll": true, "Rename": true, "Mkdir": true,
	"MkdirAll": true, "MkdirTemp": true, "ReadDir": true, "Stat": true, "Lstat": true,
	"Chdir": true, "Chmod": true, "Truncate": true, "Symlink": true, "Link": true,
	"Readlink": true, "DirFS": true, "OpenRoot": true, "Chtimes": true, "Chown": true,
	"Lchown": true, "CopyFS": true,
}

var filepathFS = map[string]bool{"Walk": true, "WalkDir": true, "Glob": true, "EvalSymlinks": true}

func TestOnlyStorageTouchesTheFileSystem(t *testing.T) {
	for _, s := range sources(t) {
		if s.pkg == "internal/storage" {
			continue
		}
		im := imports(s)
		if _, ok := im["io/ioutil"]; ok {
			t.Errorf("%s imports io/ioutil", s.rel)
		}
		osName, filepathName := im["os"], im["path/filepath"]
		// A dot import (or a blank one) would hide the package name the
		// selector check below looks for.
		if osName == "." || filepathName == "." {
			t.Errorf("%s dot-imports os or path/filepath, which hides file system calls from this check", s.rel)
		}
		ast.Inspect(s.file, func(n ast.Node) bool {
			sel, ok := n.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			x, ok := sel.X.(*ast.Ident)
			if !ok {
				return true
			}
			pos := s.fset.Position(sel.Pos())
			if osName != "" && x.Name == osName && osFS[sel.Sel.Name] {
				t.Errorf("%s:%d: os.%s outside internal/storage", s.rel, pos.Line, sel.Sel.Name)
			}
			if filepathName != "" && x.Name == filepathName && filepathFS[sel.Sel.Name] {
				t.Errorf("%s:%d: filepath.%s outside internal/storage", s.rel, pos.Line, sel.Sel.Name)
			}
			return true
		})
	}
}

func TestOnlyStorageKnowsWhereWorkspacesAre(t *testing.T) {
	for _, s := range sources(t) {
		if s.pkg == "internal/storage" {
			continue
		}
		ast.Inspect(s.file, func(n ast.Node) bool {
			lit, ok := n.(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				return true
			}
			if v, err := strconv.Unquote(lit.Value); err == nil && strings.Contains(v, "workspace") {
				t.Errorf("%s:%d: a string with `workspace` outside internal/storage", s.rel, s.fset.Position(lit.Pos()).Line)
			}
			return true
		})
	}
}

func TestNothingImportsC(t *testing.T) {
	for _, s := range sources(t) {
		if _, ok := imports(s)["C"]; ok {
			t.Errorf("%s imports \"C\": the module is built without cgo", s.rel)
		}
	}
}

// goTool runs the go command in the module, without a workspace and without
// touching go.mod or go.sum.
func goTool(t *testing.T, args ...string) []byte {
	t.Helper()
	gobin, err := exec.LookPath("go")
	if err != nil {
		t.Skip("go is not on PATH")
	}
	cmd := exec.Command(gobin, args...)
	cmd.Dir = moduleRoot(t)
	cmd.Env = append(os.Environ(), "GOWORK=off", "GOFLAGS=-mod=readonly", "CGO_ENABLED=0")
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("go %s: %v\n%s", strings.Join(args, " "), err, errb.String())
	}
	return out.Bytes()
}

// licences is every module of the module graph and the licence its LICENSE file
// carries, written by hand from those files. A module that is not here fails
// TestEveryModuleIsOnTheLicenceList: adding a dependency is a decision to make
// here, with its licence read. Allowed: MIT, Apache-2.0, BSD-2-Clause,
// BSD-3-Clause, ISC.
var licences = map[string]string{
	"github.com/bahlo/generic-list-go":            "BSD-3-Clause",
	"github.com/buger/jsonparser":                 "MIT",
	"github.com/davecgh/go-spew":                  "ISC",
	"github.com/dlclark/regexp2":                  "MIT",
	"github.com/google/go-cmdtest":                "Apache-2.0",
	"github.com/google/go-cmp":                    "BSD-3-Clause",
	"github.com/google/renameio":                  "Apache-2.0",
	"github.com/invopop/jsonschema":               "MIT",
	"github.com/pb33f/ordered-map/v2":             "Apache-2.0",
	"github.com/pmezard/go-difflib":               "BSD-2-Clause",
	"github.com/santhosh-tekuri/jsonschema/v6":    "Apache-2.0",
	"github.com/stretchr/testify":                 "MIT",
	"github.com/yuin/goldmark":                    "MIT",
	"go.yaml.in/yaml/v3":                          "Apache-2.0",
	"go.yaml.in/yaml/v4":                          "Apache-2.0",
	"golang.org/x/mod":                            "BSD-3-Clause",
	"golang.org/x/net":                            "BSD-3-Clause",
	"golang.org/x/sync":                           "BSD-3-Clause",
	"golang.org/x/sys":                            "BSD-3-Clause",
	"golang.org/x/telemetry":                      "BSD-3-Clause",
	"golang.org/x/text":                           "BSD-3-Clause",
	"golang.org/x/tools":                          "BSD-3-Clause",
	"golang.org/x/tools/go/expect":                "BSD-3-Clause",
	"golang.org/x/tools/go/packages/packagestest": "BSD-3-Clause",
	"golang.org/x/vuln":                           "BSD-3-Clause",
	"gopkg.in/yaml.v3":                            "Apache-2.0",
	modulePath:                                    "(this module)",
}

type module struct {
	Path    string
	Version string
	Dir     string
}

func graph(t *testing.T) []module {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(goTool(t, "list", "-m", "-json", "all")))
	var mods []module
	for dec.More() {
		var m module
		if err := dec.Decode(&m); err != nil {
			t.Fatal(err)
		}
		mods = append(mods, m)
	}
	if len(mods) < 3 {
		t.Fatalf("go list -m all gave %d modules", len(mods))
	}
	return mods
}

func TestEveryModuleIsOnTheLicenceList(t *testing.T) {
	allowed := map[string]bool{"MIT": true, "Apache-2.0": true, "BSD-2-Clause": true, "BSD-3-Clause": true, "ISC": true, "(this module)": true}
	for _, m := range graph(t) {
		lic, ok := licences[m.Path]
		if !ok {
			t.Errorf("module %s %s has no entry in the licence list; read its LICENSE and add it, or drop the dependency", m.Path, m.Version)
			continue
		}
		if !allowed[lic] {
			t.Errorf("module %s is under %s, which is not an allowed licence", m.Path, lic)
		}
	}
	// The list names no module the graph does not have.
	have := map[string]bool{}
	for _, m := range graph(t) {
		have[m.Path] = true
	}
	var stale []string
	for p := range licences {
		if !have[p] {
			stale = append(stale, p)
		}
	}
	sort.Strings(stale)
	if len(stale) > 0 {
		t.Errorf("licence list names modules the module graph does not have: %v", stale)
	}
}

// licenceMarkers tells a licence text from the others by a phrase of it.
func licenceMatches(name, text string) bool {
	switch name {
	case "MIT":
		return strings.Contains(text, "Permission is hereby granted, free of charge")
	case "Apache-2.0":
		return strings.Contains(text, "Apache License")
	case "ISC":
		return strings.Contains(text, "Permission to use, copy, modify, and/or distribute this software")
	case "BSD-3-Clause":
		return strings.Contains(text, "Redistributions in binary form") && strings.Contains(text, "Neither the name")
	case "BSD-2-Clause":
		return strings.Contains(text, "Redistributions in binary form") && !strings.Contains(text, "Neither the name")
	}
	return true
}

// TestListedLicencesAreWhatTheFilesSay checks the hand-written list against the
// LICENSE files in the module cache, for every module the cache has.
func TestListedLicencesAreWhatTheFilesSay(t *testing.T) {
	cache := strings.TrimSpace(string(goTool(t, "env", "GOMODCACHE")))
	checked := 0
	for _, m := range graph(t) {
		lic := licences[m.Path]
		if lic == "" || lic == "(this module)" {
			continue
		}
		dir := m.Dir
		if dir == "" {
			dir = filepath.Join(cache, filepath.FromSlash(m.Path)+"@"+m.Version)
		}
		var text string
		for _, name := range []string{"LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", "LICENCE"} {
			if data, err := os.ReadFile(filepath.Join(dir, name)); err == nil {
				text = string(data)
				break
			}
		}
		if text == "" {
			continue // not in the cache: nothing to check against
		}
		checked++
		if !licenceMatches(lic, text) {
			t.Errorf("%s: the list says %s, the LICENSE file does not read like it", m.Path, lic)
		}
	}
	if checked < 10 {
		t.Errorf("only %d licences could be checked against files", checked)
	}
}

// binaryModules are the modules whose code is in the binary, besides the
// module's own. Anything else in `go list -deps ./cmd/jig-next` is a new
// dependency of what users run, and fails here.
var binaryModules = []string{
	"github.com/santhosh-tekuri/jsonschema/v6",
	"go.yaml.in/yaml/v3",
	"golang.org/x/text",
}

func TestTheBinaryDependsOnlyOnTheListedModules(t *testing.T) {
	out := goTool(t, "list", "-deps", "-f", "{{with .Module}}{{.Path}}{{end}}", "./cmd/jig-next")
	set := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		if line = strings.TrimSpace(line); line != "" && line != modulePath {
			set[line] = true
		}
	}
	var got []string
	for p := range set {
		got = append(got, p)
	}
	sort.Strings(got)
	want := append([]string(nil), binaryModules...)
	sort.Strings(want)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("modules in the binary:\n got  %v\n want %v", got, want)
	}
	for p := range set {
		if strings.Contains(p, "invopop") || strings.HasPrefix(p, "go.yaml.in/yaml/v4") {
			t.Errorf("the binary depends on %s, which generates schemas in tests only", p)
		}
	}
}
