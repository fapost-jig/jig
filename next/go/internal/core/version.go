package core

import (
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/errs"
	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// Version is the version of the framework checkout at ctx.Root, as `jig
// --version` says it (jig_source_version): the declared `X.Y.Z` when HEAD
// carries the release tag `vX.Y.Z`, otherwise `X.Y.Z+<short sha>`, or
// `X.Y.Z+unknown` when the checkout is not a git checkout of its own.
func Version(ctx Ctx) (string, error) {
	root := ctx.Root
	if root == "" {
		return "", errs.New(errs.Failed, "the framework checkout is unknown: JIG_NEXT_ROOT is not set (run through scripts/jig-next-go)")
	}
	if !storage.IsSourceRoot(root) {
		return "", errs.New(errs.Failed, "%s is not a framework source checkout", root)
	}
	declared, ok := storage.DeclaredVersion(root)
	if !ok {
		return "", errs.New(errs.Failed, "cannot read the version %s declares in scripts/lib/version.sh", root)
	}
	isGit := ownGitCheckout(ctx, root)
	if isGit && atReleaseTag(ctx, root, declared) {
		return declared, nil
	}
	if isGit {
		if r, err := ctx.Exec.Git(root, "rev-parse", "--short=7", "HEAD"); err == nil && r.Code == 0 {
			if sha := strings.TrimRight(r.Stdout, "\n"); sha != "" {
				return declared + "+" + sha, nil
			}
		}
	}
	return declared + "+unknown", nil
}

// ownGitCheckout is _jig_source_git: dir is the top of a git checkout of its
// own, not merely inside somebody else's repository.
func ownGitCheckout(ctx Ctx, dir string) bool {
	r, err := ctx.Exec.Git(dir, "rev-parse", "--show-toplevel")
	if err != nil || r.Code != 0 {
		return false
	}
	top := strings.TrimRight(r.Stdout, "\n")
	return top != "" && storage.SamePhysicalDir(top, dir)
}

// atReleaseTag is jig_source_release: the declared version is a release number
// and `v<declared>` points at HEAD.
func atReleaseTag(ctx Ctx, dir, declared string) bool {
	if !releaseVersion(declared) {
		return false
	}
	r, err := ctx.Exec.Git(dir, "tag", "--points-at", "HEAD")
	if err != nil || r.Code != 0 {
		return false
	}
	for _, tag := range strings.Split(r.Stdout, "\n") {
		if tag == "v"+declared {
			return true
		}
	}
	return false
}

// releaseVersion is jig_release_version: exactly three non-empty fields of
// digits.
func releaseVersion(v string) bool {
	fields := strings.Split(v, ".")
	if len(fields) != 3 {
		return false
	}
	for _, f := range fields {
		if f == "" {
			return false
		}
		for i := 0; i < len(f); i++ {
			if f[i] < '0' || f[i] > '9' {
				return false
			}
		}
	}
	return true
}
