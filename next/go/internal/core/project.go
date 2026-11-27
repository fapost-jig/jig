package core

import (
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/errs"
	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// Project is the checkout a command runs in: JIG_PROJECT.
type Project struct {
	Root string
}

// gitTop is jig_repo_root: git's answer for the top of the working tree.
func gitTop(ctx Ctx) (string, bool) {
	r, err := ctx.Exec.Git(ctx.cwd(), "rev-parse", "--show-toplevel")
	if err != nil || r.Code != 0 {
		return "", false
	}
	top := strings.TrimRight(r.Stdout, "\n")
	return top, top != ""
}

// RequireRepo is jig_require_repo: the repository root, made physical.
func RequireRepo(ctx Ctx) (Project, error) {
	top, ok := gitTop(ctx)
	if !ok {
		return Project{}, errs.New(errs.NotARepository, "not inside a git repository")
	}
	root := storage.PhysicalDir(top)
	if root == "" {
		return Project{}, errs.New(errs.Failed, "cannot resolve the repository root: %s", top)
	}
	return Project{Root: root}, nil
}

// RequireInit is jig_require_init: a repository Jig has been set up in.
func RequireInit(ctx Ctx) (Project, error) {
	p, err := RequireRepo(ctx)
	if err != nil {
		return p, err
	}
	if !storage.HasConfig(p.Root) {
		return p, errs.New(errs.NotInitialised, "project is not initialised; run: jig init")
	}
	return p, nil
}
