//go:build !windows

package proc

import "os/exec"

// hideWindow is a no-op outside Windows.
func hideWindow(*exec.Cmd) {}
