//go:build windows

package proc

import (
	"os/exec"
	"syscall"
)

// createNoWindow is CREATE_NO_WINDOW: a child of a console program gets no
// console window of its own.
const createNoWindow = 0x08000000

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
}
