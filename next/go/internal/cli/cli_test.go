package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/fapost-jig/jig/next/go/internal/proc"
)

func do(t *testing.T, env map[string]string, args ...string) (code int, out, errOut string) {
	t.Helper()
	var o, e bytes.Buffer
	x, _ := proc.Fake(nil)
	code = run(args, func(k string) string { return env[k] }, x, &o, &e)
	return code, o.String(), e.String()
}

func TestNoArgumentsIsHelp(t *testing.T) {
	for _, args := range [][]string{nil, {"help"}, {"-h"}, {"--help"}} {
		code, out, errOut := do(t, nil, args...)
		if code != 0 || !strings.Contains(out, "Usage: jig-next") || errOut != "" {
			t.Errorf("%v: %d %q %q", args, code, out, errOut)
		}
	}
}

func TestUnknownCommandIsAUsageError(t *testing.T) {
	code, out, errOut := do(t, nil, "task", "list")
	if code != 1 || out != "" || errOut != "jig: error: unknown command: task\n" {
		t.Errorf("%d %q %q", code, out, errOut)
	}
}

func TestVersionNeedsItsRoot(t *testing.T) {
	code, _, errOut := do(t, nil, "--version")
	if code != 1 || !strings.HasPrefix(errOut, "jig: error: ") || !strings.Contains(errOut, "JIG_NEXT_ROOT") {
		t.Errorf("%d %q", code, errOut)
	}
}

func TestVersionIsAlsoASubcommand(t *testing.T) {
	code, out, errOut := do(t, nil, "version")
	if code != 1 || out != "" || !strings.HasPrefix(errOut, "jig: error: ") || !strings.Contains(errOut, "JIG_NEXT_ROOT") {
		t.Errorf("%d %q %q", code, out, errOut)
	}
	code, _, errOut = do(t, nil, "version", "--json")
	if code != 1 || errOut != "jig: error: version: unknown option: --json\n" {
		t.Errorf("%d %q", code, errOut)
	}
}

func TestVersionRefusesAnArgument(t *testing.T) {
	code, _, errOut := do(t, nil, "--version", "--json")
	if code != 1 || errOut != "jig: error: version: unknown option: --json\n" {
		t.Errorf("%d %q", code, errOut)
	}
}

func TestBadJigNowIsRefusedBeforeAnyCommand(t *testing.T) {
	for _, args := range [][]string{nil, {"--help"}, {"--version"}, {"nonsense"}} {
		code, out, errOut := do(t, map[string]string{"JIG_NOW": "soon"}, args...)
		want := "jig: error: JIG_NOW must be seconds since the epoch, got 'soon'\n"
		if code != 1 || out != "" || errOut != want {
			t.Errorf("%v: %d %q %q", args, code, out, errOut)
		}
	}
}
