package core

import "strings"

// globPattern is jig_glob_pattern_v: a frontmatter `paths` glob as the pattern
// of a bash `case`, which has exactly one wildcard, `*`; `?` and `[...]` are
// literals, `**` any depth, and a trailing `/` means everything under it.
func globPattern(glob string) string {
	p := strings.ReplaceAll(glob, `\`, `\\`)
	p = strings.ReplaceAll(p, "?", `\?`)
	p = strings.ReplaceAll(p, "[", `\[`)
	p = strings.ReplaceAll(p, "]", `\]`)
	p = strings.ReplaceAll(p, "**/", "*")
	p = strings.ReplaceAll(p, "**", "*")
	if strings.HasSuffix(p, "/") {
		p += "*"
	}
	return p
}

// casePatternMatch is a bash `case` match of s against pattern, where the
// pattern holds only `*` (any run of characters, `/` included) and backslash
// escapes, which is all globPattern produces.
func casePatternMatch(pattern, s string) bool {
	px, sx := 0, 0
	star, mark := -1, 0
	for sx < len(s) {
		if px < len(pattern) {
			c := pattern[px]
			switch {
			case c == '*':
				star, mark = px, sx
				px++
				continue
			case c == '\\' && px+1 < len(pattern):
				if pattern[px+1] == s[sx] {
					px += 2
					sx++
					continue
				}
			case c == s[sx]:
				px++
				sx++
				continue
			}
		}
		if star < 0 {
			return false
		}
		px = star + 1
		mark++
		sx = mark
	}
	for px < len(pattern) && pattern[px] == '*' {
		px++
	}
	return px == len(pattern)
}

// pathMatchesAny is jig_path_matches_any: glob matches at least one of files.
func pathMatchesAny(glob string, files []string) bool {
	pattern := globPattern(glob)
	for _, f := range files {
		if f != "" && casePatternMatch(pattern, f) {
			return true
		}
	}
	return false
}
