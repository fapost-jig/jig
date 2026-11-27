package core

import (
	"sort"
	"strings"
)

// baseRef is jig_base_ref: the ref a base branch is judged by, origin first, or
// "" when neither exists.
func baseRef(ctx Ctx, root, name string) string {
	if name == "" {
		return ""
	}
	for _, ref := range []string{"refs/remotes/origin/" + name, "refs/heads/" + name} {
		r, err := ctx.Exec.Git(root, "rev-parse", "--verify", "--quiet", ref+"^{commit}")
		if err == nil && r.Code == 0 {
			return ref
		}
	}
	return ""
}

// gitLines runs git in root and gives the lines it printed; none when it fails.
func gitLines(ctx Ctx, root string, args ...string) []string {
	r, err := ctx.Exec.Git(root, args...)
	if err != nil || r.Code != 0 {
		return nil
	}
	return strings.Split(r.Stdout, "\n")
}

// touchedFiles is jig_git_touched_files --base-branch: the union of the diff
// against the merge base with base, the staged and unstaged diffs and the
// untracked files, sorted and unique; blank lines are dropped.
func touchedFiles(ctx Ctx, root, base string) []string {
	var all []string
	if ref := baseRef(ctx, root, base); ref != "" {
		if r, err := ctx.Exec.Git(root, "merge-base", ref, "HEAD"); err == nil && r.Code == 0 {
			mb := strings.TrimRight(r.Stdout, "\n")
			all = append(all, gitLines(ctx, root, "diff", "--name-only", mb)...)
		}
	}
	all = append(all, gitLines(ctx, root, "diff", "--cached", "--name-only")...)
	all = append(all, gitLines(ctx, root, "diff", "--name-only")...)
	all = append(all, gitLines(ctx, root, "ls-files", "--others", "--exclude-standard")...)
	seen := map[string]bool{}
	var out []string
	for _, l := range all {
		if l == "" || seen[l] {
			continue
		}
		seen[l] = true
		out = append(out, l)
	}
	sort.Strings(out)
	return out
}
