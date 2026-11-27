package storage

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// IsSourceRoot is jig_is_source_root: dir is a framework source checkout when
// it has skills/ and templates/ and scripts/jig.
func IsSourceRoot(dir string) bool {
	return isDir(filepath.Join(dir, "skills")) &&
		isDir(filepath.Join(dir, "templates")) &&
		isFile(filepath.Join(dir, "scripts", "jig"))
}

func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

func isFile(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.Mode().IsRegular()
}

// IsDir reports whether p is a directory.
func IsDir(p string) bool { return isDir(p) }

// IsFile reports whether p is a regular file.
func IsFile(p string) bool { return isFile(p) }

// declaredVersion is the line shape of jig_declared_version:
// JIG_VERSION="<value free of quotes and spaces>", blanks after it allowed.
var declaredVersion = regexp.MustCompile(`^JIG_VERSION="([^" ]+)"[ \t\n\v\f\r]*$`)

// DeclaredVersion is the version a framework checkout declares in
// scripts/lib/version.sh, read without running anything (jig_declared_version):
// ok only when exactly one line has the shape JIG_VERSION="<version>".
func DeclaredVersion(root string) (version string, ok bool) {
	data, err := os.ReadFile(filepath.Join(root, "scripts", "lib", "version.sh"))
	if err != nil {
		return "", false
	}
	found := 0
	for _, line := range splitLines(string(data)) {
		if m := declaredVersion.FindStringSubmatch(line); m != nil {
			version = m[1]
			found++
		}
	}
	if found != 1 {
		return "", false
	}
	return version, true
}

// SamePhysicalDir reports whether a and b are the same directory once links are
// resolved (the `cd -P … && pwd -P` comparison of _jig_source_git).
func SamePhysicalDir(a, b string) bool {
	pa, err := filepath.EvalSymlinks(a)
	if err != nil {
		return false
	}
	pb, err := filepath.EvalSymlinks(b)
	if err != nil {
		return false
	}
	return pa == pb
}

// PhysicalDir is dir with links resolved, or "" when it cannot be.
func PhysicalDir(dir string) string {
	p, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return ""
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return ""
	}
	return Slash(abs)
}

// Slash is p with the operating system's separator written as `/`: the form
// every path takes when storage hands it to core, so that core's string
// operations (prefix, join, relative) hold on Windows too.
func Slash(p string) string { return slashWith(p, filepath.Separator) }

func slashWith(p string, sep rune) string {
	if sep == '/' {
		return p
	}
	return strings.ReplaceAll(p, string(sep), "/")
}
