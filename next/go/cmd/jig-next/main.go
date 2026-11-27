// Command jig-next is the Go implementation of Jig's next version: a skeleton
// with --version and --help, grown beside the bash implementation.
package main

import (
	"os"

	"github.com/fapost-jig/jig/next/go/internal/cli"
)

func main() {
	os.Exit(cli.Main(os.Args[1:], os.Getenv, os.Stdin, os.Stdout, os.Stderr))
}
