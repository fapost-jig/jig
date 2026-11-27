// Package core holds what Jig does, as functions of a Ctx: nothing here reads
// the process environment, the clock or the machine except through it.
package core

import (
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
}
