package core

import "testing"

func TestGlobPattern(t *testing.T) {
	for glob, want := range map[string]string{
		"src/**":        "src/*",
		"**/*.php":      "*.php",
		"src/**/a.go":   "src/*a.go",
		"docs/":         "docs/*",
		"docs/**/":      "docs/*",
		"a?b":           `a\?b`,
		"a[1]":          `a\[1\]`,
		`a\b`:           `a\\b`,
		"plain/file.go": "plain/file.go",
	} {
		if got := globPattern(glob); got != want {
			t.Errorf("globPattern(%q) = %q, want %q", glob, got, want)
		}
	}
}

func TestPathMatchesAny(t *testing.T) {
	files := []string{"README.md", "src/Flow/a.php", "src/deep/er/b.go", "docs/x?y", "docs/a[1]"}
	for _, tc := range []struct {
		glob string
		want bool
	}{
		{"README.md", true},
		{"README", false},
		{"src/Flow/**", true},
		{"src/**/b.go", true},
		{"**/*.php", true},
		{"*.go", true}, // a bare `*` crosses `/`, as in a bash case pattern
		{"src/", true},
		{"lib/", false},
		{"docs/x?y", true},
		{"docs/x_y", false},
		{"docs/x?", false},
		{"docs/a[1]", true},
		{"docs/a1", false},
		{"nothing/**", false},
		{"", false},
	} {
		if got := pathMatchesAny(tc.glob, files); got != tc.want {
			t.Errorf("pathMatchesAny(%q) = %v, want %v", tc.glob, got, tc.want)
		}
	}
	if pathMatchesAny("*", []string{""}) {
		t.Error("an empty line is not a file")
	}
}
