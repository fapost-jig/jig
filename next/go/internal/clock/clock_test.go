package clock

import (
	"strings"
	"testing"
	"time"

	"github.com/fapost-jig/jig/next/go/internal/errs"
)

func TestValid(t *testing.T) {
	for _, ok := range []string{"", "0", "1790000000", "00001790000000", "99999999999999"} {
		if !Valid(ok) {
			t.Errorf("Valid(%q) = false, want true", ok)
		}
	}
	for _, bad := range []string{"abc", "-1", "1.5", " 1", "1 ", "100000000000000", "0x10", "١٢"} {
		if Valid(bad) {
			t.Errorf("Valid(%q) = true, want false", bad)
		}
	}
}

func TestNewRefusesWithTheBashMessage(t *testing.T) {
	_, err := New("tomorrow")
	if err == nil {
		t.Fatal("want an error")
	}
	e, ok := err.(*errs.Error)
	if !ok || e.Code != errs.Failed {
		t.Fatalf("want a failed error, got %#v", err)
	}
	if want := "JIG_NOW must be seconds since the epoch, got 'tomorrow'"; e.Message != want {
		t.Errorf("message = %q, want %q", e.Message, want)
	}
}

func TestPinnedClock(t *testing.T) {
	c, err := New("1790000000")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := c.UTC(), "2026-09-21T14:13:20Z"; got != want {
		t.Errorf("UTC = %q, want %q", got, want)
	}
	if got := c.Today(); len(got) != 10 || got[4] != '-' {
		t.Errorf("Today = %q", got)
	}
	if got, want := c.Today(), time.Unix(1790000000, 0).Local().Format("2006-01-02"); got != want {
		t.Errorf("Today = %q, want %q", got, want)
	}
}

func TestLeadingZerosAreDecimal(t *testing.T) {
	a, err := New("0000000010")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := New("10")
	if a.UTC() != b.UTC() {
		t.Errorf("%s != %s", a.UTC(), b.UTC())
	}
	if !strings.HasPrefix(a.UTC(), "1970-01-01T00:00:10") {
		t.Errorf("UTC = %s", a.UTC())
	}
}

func TestEmptyIsTheRealClock(t *testing.T) {
	c, err := New("")
	if err != nil {
		t.Fatal(err)
	}
	if d := time.Since(c.Now()); d < 0 || d > time.Minute {
		t.Errorf("real clock is %v off", d)
	}
	if time.Since(Clock{}.Now()) > time.Minute {
		t.Error("zero Clock is not the real clock")
	}
}
