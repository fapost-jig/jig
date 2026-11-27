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

Usage: jig-next [version | --version | --help | context ...]

  context [...]   relevant knowledge for a task, as jig context does
  version         print the version, as jig version does
  --version       the same
  -h, --help      print this help

Environment:
  JIG_NEXT_ROOT   the framework checkout this binary belongs to; scripts/jig-next-go sets it
  JIG_NOW         seconds since the epoch, pins the clock
`

// Main runs one invocation: args without the program name, env answering the
// environment. It returns the exit status.
func Main(args []string, env func(string) string, stdin io.Reader, stdout, stderr io.Writer) int {
	return run(args, env, stdin, proc.Real(), stdout, stderr)
}

func run(args []string, env func(string) string, stdin io.Reader, exec proc.Exec, stdout, stderr io.Writer) int {
	// A malformed JIG_NOW is refused here, once, before any command.
	clk, err := clock.New(env("JIG_NOW"))
	if err != nil {
		return fail(stderr, err)
	}
	ctx := core.Ctx{Root: env("JIG_NEXT_ROOT"), Exec: exec, Clock: clk, Env: env, Stdin: stdin}

	cmd := "help"
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "help", "-h", "--help":
		fmt.Fprint(stdout, usage)
		return 0
	case "version", "--version":
		if len(args) > 0 {
			return fail(stderr, errs.New(errs.Usage, "version: unknown option: %s", args[0]))
		}
		v, err := core.Version(ctx)
		if err != nil {
			return fail(stderr, err)
		}
		fmt.Fprintf(stdout, "jig %s\n", v)
		return 0
	case "context":
		// The dispatcher notes that a session works here before the command runs.
		core.CheckoutRecord(ctx, append([]string{cmd}, args...))
		return write(core.Context(ctx, args), stdout, stderr)
	default:
		return fail(stderr, errs.New(errs.Usage, "unknown command: %s", cmd))
	}
}

// write prints what a command printed, chunk by chunk in order, and gives its
// exit status.
func write(o core.Output, stdout, stderr io.Writer) int {
	for _, c := range o.Chunks {
		if c.Stderr {
			fmt.Fprint(stderr, c.Text)
		} else {
			fmt.Fprint(stdout, c.Text)
		}
	}
	return o.Code
}

// fail prints what went wrong, as `jig: error:` does, which the next implementation must keep, and gives the exit status.
func fail(stderr io.Writer, err error) int {
	fmt.Fprintf(stderr, "jig: error: %s\n", err.Error())
	return 1
}
