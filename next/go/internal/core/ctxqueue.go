package core

import (
	"fmt"
	"strings"
	"time"

	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// queueLines is _ctx_queue_lines: the task's place in the queue as `queue:`
// lines after its workspace, and a pause asked of it that it has not honoured.
func queueLines(ctx Ctx, p Project, id string) string {
	var b strings.Builder
	if place, ok := storage.ReadQueuePlace(p.Root, id); ok {
		level := place.Level
		if level == "-" {
			level = "the top level"
		}
		if place.Priority == "-" {
			fmt.Fprintf(&b, "%-10s %d of %d on %s, no priority\n", "queue:", place.Rank, place.Count, level)
		} else {
			fmt.Fprintf(&b, "%-10s %d of %d on %s, priority %s\n", "queue:", place.Rank, place.Count, level, place.Priority)
		}
		for _, d := range place.Deps {
			if d.On != "" {
				fmt.Fprintf(&b, "%-10s waits for %s: %s\n", "queue:", d.On, d.Reason)
			}
		}
	}
	if at, reason, ok := storage.PauseRequest(p.Root, id); ok {
		ago := utcAgo(ctx, at)
		switch ago {
		case "":
			ago = "at " + at
		case "just now":
		default:
			ago += " ago"
		}
		if reason != "" {
			reason = " (" + reason + ")"
		}
		fmt.Fprintf(&b, "%-10s pause requested %s%s; honoured when the next stage of the task resolves its context\n", "queue:", ago, reason)
	}
	return b.String()
}

// utcAgo is jig_utc_ago: how long ago a UTC ISO time was, in words, measured
// against the clock; "" when the time does not parse.
func utcAgo(ctx Ctx, at string) string {
	t, err := time.Parse("2006-01-02T15:04:05Z", at)
	if err != nil {
		return ""
	}
	d := ctx.Clock.Now().Unix() - t.Unix()
	switch {
	case d < 60:
		return "just now"
	case d < 3600:
		return fmt.Sprintf("%d min", d/60)
	case d < 172800:
		return fmt.Sprintf("%d h", d/3600)
	}
	return fmt.Sprintf("%d days", d/86400)
}
