// Package cli turns an argument list into a call of core and the call's result
// into output and an exit status. It is the only place that prints.
package cli

import (
	"fmt"
	"io"

	"github.com/fapost-jig/jig/next/go/internal/clock"
	"github.com/fapost-jig/jig/next/go/internal/core"
	"github.com/fapost-jig/jig/next/go/internal/errs"
	"github.com/fapost-jig/jig/next/go/internal/proc"
)

const usage = `jig-next — the next implementation of Jig (a skeleton: it has no commands yet)

Usage: jig-next [--version | --help]

  --version       print the version, as jig --version does
  -h, --help      print this help

Environment:
  JIG_NEXT_ROOT   the framework checkout this binary belongs to; scripts/jig-next-go sets it
  JIG_NOW         seconds since the epoch, pins the clock
`

// Main runs one invocation: args without the program name, env answering the
// environment. It returns the exit status.
func Main(args []string, env func(string) string, stdout, stderr io.Writer) int {
	return run(args, env, proc.Real(), stdout, stderr)
}

func run(args []string, env func(string) string, exec proc.Exec, stdout, stderr io.Writer) int {
	// A malformed JIG_NOW is refused here, once, before any command.
	clk, err := clock.New(env("JIG_NOW"))
	if err != nil {
		return fail(stderr, err)
	}
	ctx := core.Ctx{Root: env("JIG_NEXT_ROOT"), Exec: exec, Clock: clk, Env: env}

	cmd := "help"
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "help", "-h", "--help":
		fmt.Fprint(stdout, usage)
		return 0
	case "--version":
		if len(args) > 0 {
			return fail(stderr, errs.New(errs.Usage, "version: unknown option: %s", args[0]))
		}
		v, err := core.Version(ctx)
		if err != nil {
			return fail(stderr, err)
		}
		fmt.Fprintf(stdout, "jig %s\n", v)
		return 0
	default:
		return fail(stderr, errs.New(errs.Usage, "unknown command: %s", cmd))
	}
}

// fail prints what went wrong, as `jig: error:` does, and gives the exit status.
func fail(stderr io.Writer, err error) int {
	fmt.Fprintf(stderr, "jig-next: error: %s\n", err.Error())
	return 1
}
