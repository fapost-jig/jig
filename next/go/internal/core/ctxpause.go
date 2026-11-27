package core

import (
	"errors"
	"fmt"

	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// honourPause is _ctx_honour_pause: a named task resolving the context of a
// named stage is entering that stage, and a pause asked of the task is honoured
// there, before any context is printed. It reports whether the task was paused
// (exit status 4 of the command). When nothing was asked, or the pause could
// not be made, the context is read as usual and the request stays.
func honourPause(ctx Ctx, p Project, id, stage string, out *Output) bool {
	if _, _, ok := storage.PauseRequest(p.Root, id); !ok {
		return false
	}
	text, paused, err := pauseIfRequested(ctx, p, id, stage)
	switch {
	case paused:
		out.stdout(text + "\n")
		out.stdout(fmt.Sprintf("next:      a person asked for this pause; do not start the %s stage, end the session; jig task resume %s continues the task\n", stage, id))
		out.Code = 4
		return true
	case err != nil:
		out.stderr(fmt.Sprintf("jig: warning: context: the pause requested for %s was not honoured: jig: error: %s\n", id, err.Error()))
	}
	return false
}

// pauseIfRequested is `jig task pause <id> --if-requested --stage <stage>`, done
// here instead of by another process: nothing when the task is paused already
// or no request stands; else the request leaves the queue, the task is paused
// and the `paused:` line is the text. The request goes before the pause is set.
func pauseIfRequested(ctx Ctx, p Project, id, stage string) (text string, paused bool, err error) {
	if err := guardWrite(ctx, p, id, "task pause"); err != nil {
		return "", false, err
	}
	if v, _ := storage.TaskStateGet(p.Root, id, "paused"); v == "true" {
		return "", false, nil
	}
	at, reason, ok := storage.PauseRequest(p.Root, id)
	if !ok {
		return "", false, nil
	}
	if v, _ := storage.TaskStateGet(p.Root, id, "autopilot"); v == "on" {
		return "", false, errors.New("task pause: the autopilot journal is not written by this implementation yet")
	}
	if err := storage.QueueCancelRequest(p.Root, "task:"+id, "pause", ctx.Clock); err != nil {
		if errors.Is(err, storage.ErrNoRequest) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("task pause: cannot take the pause request of %s out of the queue: %v", id, err)
	}
	why := "pause requested at " + at
	if reason != "" {
		why += ": " + reason
	}
	for _, kv := range [][2]string{{"paused", "true"}, {"paused_at", ctx.Clock.Today()}, {"paused_reason", why}} {
		if err := storage.TaskStateSet(p.Root, id, kv[0], kv[1], ctx.Clock); err != nil && !errors.Is(err, storage.ErrRevisionNotRaised) {
			return "", false, fmt.Errorf("task pause: cannot write the state of %s: %v", id, err)
		}
	}
	return fmt.Sprintf("paused: %s (%s); stage %s not entered", id, why, stage), true, nil
}
