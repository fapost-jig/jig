// Package core holds what Jig does, as functions of a Ctx: nothing here reads
// the process environment, the clock or the machine except through it.
package core

import (
	"io"

	"github.com/fapost-jig/jig/next/go/internal/clock"
	"github.com/fapost-jig/jig/next/go/internal/proc"
)

// Ctx is everything a function of core may depend on.
type Ctx struct {
	// Root is the framework checkout the program belongs to ("" when unknown).
	Root  string
	Exec  proc.Exec
	Clock clock.Clock
	// Env answers an environment variable; "" when it is not set.
	Env func(key string) string
	// FileClock is the real clock, which a file's mtime is compared against; the
	// zero value is the machine's. JIG_NOW pins Clock, never this one.
	FileClock clock.Clock
	// Cwd is the directory the program was started in; "" is ".".
	Cwd string
	// Stdin is what `-` reads (a file list on stdin); nil is an empty input.
	Stdin io.Reader
}

// cwd is the directory git is asked from when no checkout is named yet.
func (c Ctx) cwd() string {
	if c.Cwd == "" {
		return "."
	}
	return c.Cwd
}
