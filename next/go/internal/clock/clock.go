// Package clock is the one reading of the current time. JIG_NOW pins it, as it
// does in the bash implementation (scripts/lib/common.sh, "the clock").
package clock

import (
	"strconv"
	"time"

	"github.com/fapost-jig/jig/next/go/internal/errs"
)

// Clock answers the current instant, real or pinned.
type Clock struct {
	now func() time.Time
}

// Valid reports whether v is a usable JIG_NOW: empty (the real clock) or seconds
// since the epoch, digits only and fewer than 15 of them (jig_now_valid).
func Valid(v string) bool {
	if len(v) >= 15 {
		return false
	}
	for i := 0; i < len(v); i++ {
		if v[i] < '0' || v[i] > '9' {
			return false
		}
	}
	return true
}

// New builds the clock for the value of JIG_NOW. Anything but empty or seconds
// since the epoch is refused, never read as the real clock (jig_now_check).
// Leading zeros are allowed: bash reads the number as 10#<digits>.
func New(jigNow string) (Clock, error) {
	if !Valid(jigNow) {
		return Clock{}, errs.New(errs.Failed, "JIG_NOW must be seconds since the epoch, got '%s'", jigNow)
	}
	if jigNow == "" {
		return Clock{now: time.Now}, nil
	}
	secs, err := strconv.ParseInt(jigNow, 10, 64)
	if err != nil {
		return Clock{}, errs.New(errs.Failed, "JIG_NOW must be seconds since the epoch, got '%s'", jigNow)
	}
	at := time.Unix(secs, 0)
	return Clock{now: func() time.Time { return at }}, nil
}

// Real is the clock of the machine.
func Real() Clock { return Clock{now: time.Now} }

// Now is the current instant.
func (c Clock) Now() time.Time {
	if c.now == nil {
		return time.Now()
	}
	return c.now()
}

// Today is the local date, YYYY-MM-DD (jig_today).
func (c Clock) Today() string { return c.Now().Local().Format("2006-01-02") }

// UTC is the instant in UTC, YYYY-MM-DDTHH:MM:SSZ (jig_now_utc).
func (c Clock) UTC() string { return c.Now().UTC().Format("2006-01-02T15:04:05Z") }
