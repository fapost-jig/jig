// Package proc is the one place that starts external processes. Everything
// else asks an Exec, which a test can replace with Fake.
package proc

import (
	"bytes"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"sync"
)

// Cmd is one process to run: no shell, argv as given.
type Cmd struct {
	Name  string
	Args  []string
	Dir   string   // working directory; empty is the caller's own
	Env   []string // KEY=VALUE entries added to the environment of the caller
	Stdin string
}

// Result is what a finished process left. A process that ran and exited with a
// non-zero status is a Result with Code set, not an error: only a process that
// could not run at all is an error.
type Result struct {
	Stdout string
	Stderr string
	Code   int
}

// Exec runs processes. It is a function wrapped in a struct, not an interface
// port: there is one real implementation and one substitute for tests.
type Exec struct {
	run func(Cmd) (Result, error)
}

// Run runs c.
func (e Exec) Run(c Cmd) (Result, error) {
	if e.run == nil {
		return Result{}, errors.New("proc: no executor")
	}
	return e.run(c)
}

// Git runs git in dir. It always passes `-c core.fsmonitor=false -C <dir>`: Jig
// only asks a checkout questions and must not start the person's file system
// monitor in it.
func (e Exec) Git(dir string, args ...string) (Result, error) {
	argv := append([]string{"-c", "core.fsmonitor=false", "-C", dir}, args...)
	return e.Run(Cmd{Name: "git", Args: argv})
}

// Real runs processes on this machine with os/exec, without a shell.
func Real() Exec {
	return Exec{run: func(c Cmd) (Result, error) {
		cmd := exec.Command(c.Name, c.Args...)
		cmd.Dir = c.Dir
		cmd.Env = append(withoutGitLocation(cmd.Environ()), c.Env...)
		if c.Stdin != "" {
			cmd.Stdin = strings.NewReader(c.Stdin)
		}
		hideWindow(cmd)
		var out, errb bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &errb
		err := cmd.Run()
		res := Result{Stdout: out.String(), Stderr: errb.String()}
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			res.Code = exit.ExitCode()
			return res, nil
		}
		return res, err
	}}
}

// gitLocationEnv are the variables that point git at another repository than
// the one `-C` names; bash clears them before it asks git anything
// (jig_clear_git_location_env), and so does the executor, for every process.
var gitLocationEnv = []string{
	"GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR",
	"GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
	"GIT_INDEX_FILE", "GIT_NAMESPACE",
	"GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM",
}

// withoutGitLocation is env without the gitLocationEnv variables. A caller may
// still set one on purpose through Cmd.Env, which is appended after.
func withoutGitLocation(env []string) []string {
	out := make([]string, 0, len(env))
next:
	for _, kv := range env {
		for _, name := range gitLocationEnv {
			if strings.HasPrefix(kv, name+"=") {
				continue next
			}
		}
		out = append(out, kv)
	}
	return out
}

// Key is the table key of a call: the name and the arguments joined by a space.
func Key(name string, args ...string) string {
	return strings.Join(append([]string{name}, args...), " ")
}

// Reply is what a faked call answers.
type Reply struct {
	Stdout string
	Stderr string
	Code   int
}

// Log is the calls a Fake received, in order.
type Log struct {
	mu         sync.Mutex
	calls      []Cmd
	unexpected []Cmd
}

// Calls are the calls that the table answered.
func (l *Log) Calls() []Cmd {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]Cmd(nil), l.calls...)
}

// Unexpected are the calls the table had no row for; each also returned an error.
func (l *Log) Unexpected() []Cmd {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]Cmd(nil), l.unexpected...)
}

// Fake answers each call from table, keyed by Key(name, args...). A call with
// no row returns an error and is kept in the log's Unexpected list, so a test
// fails on a process it did not expect even if the code swallows the error.
func Fake(table map[string]Reply) (Exec, *Log) {
	log := &Log{}
	return Exec{run: func(c Cmd) (Result, error) {
		log.mu.Lock()
		defer log.mu.Unlock()
		r, ok := table[Key(c.Name, c.Args...)]
		if !ok {
			log.unexpected = append(log.unexpected, c)
			return Result{}, fmt.Errorf("proc: unexpected call: %s", Key(c.Name, c.Args...))
		}
		log.calls = append(log.calls, c)
		return Result{Stdout: r.Stdout, Stderr: r.Stderr, Code: r.Code}, nil
	}}, log
}
