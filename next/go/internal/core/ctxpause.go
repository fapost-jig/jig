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
	if _, _, ok := storage.PauseRequest(p.Root, id); !ok {
		return "", false, nil
	}
	at, reason, terr := takePauseRequest(ctx, p, id)
	if terr != nil || at == "" {
		return "", false, terr
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
	if v, _ := storage.TaskStateGet(p.Root, id, "autopilot"); v == "on" {
		if err := storage.AutopilotLog(p.Root, id, "pause", stage+" not entered: "+why, ctx.Clock); err != nil && !errors.Is(err, storage.ErrRevisionNotRaised) {
			return "", false, fmt.Errorf("task pause: cannot write the autopilot journal of %s: %v", id, err)
		}
	}
	return fmt.Sprintf("paused: %s (%s); stage %s not entered", id, why, stage), true, nil
}

// takePauseRequest is _task_pause_take_request: the request leaves the queue
// through the queue's own write, which is claimed against the revision it was
// read at. A write that landed in between is read again, up to three times;
// then the request stays. It answers when the request was made and why, and ""
// when there is none (or somebody cancelled it first).
func takePauseRequest(ctx Ctx, p Project, id string) (at, reason string, err error) {
	for tries := 0; ; {
		var ok bool
		if at, reason, ok = storage.PauseRequest(p.Root, id); !ok {
			return "", "", nil
		}
		cerr := storage.QueueCancelRequest(p.Root, "task:"+id, "pause", ctx.Clock)
		switch {
		case cerr == nil:
			return at, reason, nil
		case errors.Is(cerr, storage.ErrNoRequest):
			return "", "", nil
		case errors.Is(cerr, storage.ErrStaleRevision):
			if tries++; tries >= 3 {
				return "", "", fmt.Errorf("task pause: the queue kept changing; the pause request of %s stays", id)
			}
		default:
			return "", "", fmt.Errorf("task pause: cannot take the pause request of %s out of the queue: %v", id, cerr)
		}
	}
}
