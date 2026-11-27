package storage

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Cfg is a config.yaml or profile.yaml read the way the bash implementation
// reads it: by lines, not as YAML (scripts/lib/config.sh, _cfg_read_v and
// cfg_list_lines). The two files are "a flat YAML subset" that only these
// readers define, and for as long as bash reads the same files the Go reader
// must answer what bash answers, for every file, including the ones a YAML
// parser would refuse or read differently (a value starting with `{`, `*`, `&`
// or `!`, a `#` inside quotes, a tab, CRLF line ends).
type Cfg struct {
	lines []string
}

// ParseCfg reads the text of a config or profile file.
func ParseCfg(text string) *Cfg {
	return &Cfg{lines: splitLines(text)}
}

// ReadConfig reads project root's .ai/config.yaml. A project without one gives
// an error satisfying IsNotExist.
func ReadConfig(root string) (*Cfg, error) {
	return ReadCfgFile(filepath.Join(root, ".ai", "config.yaml"))
}

// ReadCfgFile reads the config-format file at path.
func ReadCfgFile(path string) (*Cfg, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ParseCfg(string(data)), nil
}

// Get is _cfg_read_v: the value of key, from the first line that matches
// `^<key>:[[:space:]]*` — the key is a pattern there, so a `.` in it matches any
// character, and so it does here — with everything from the first `#` cut off
// and trailing blanks trimmed. found is false when no line matches. A key that
// is not a valid pattern matches nothing.
func (c *Cfg) Get(key string) (value string, found bool) {
	re, err := regexp.Compile("^(?:" + key + "):[[:space:]]*")
	if err != nil {
		return "", false
	}
	for _, line := range c.lines {
		loc := re.FindStringIndex(line)
		if loc == nil {
			continue
		}
		v := line[loc[1]:]
		if i := strings.IndexByte(v, '#'); i >= 0 {
			v = v[:i]
		}
		return strings.TrimRight(v, " \t\n\v\f\r"), true
	}
	return "", false
}

// List is cfg_list_lines on the value of key: nothing when the key is absent or
// empty; a value written `[a, b]` loses its brackets; the rest is split at
// commas (a bare scalar is a list of one), each item trimmed of blanks and of
// one pair of double quotes, empty items dropped.
func (c *Cfg) List(key string) []string {
	raw, _ := c.Get(key)
	return SplitList(raw)
}

// SplitList is what cfg_list_lines does to a value.
func SplitList(raw string) []string {
	items := []string{}
	if raw == "" {
		return items
	}
	if strings.HasPrefix(raw, "[") && strings.HasSuffix(raw, "]") {
		raw = raw[1 : len(raw)-1]
	}
	for _, it := range strings.Split(raw, ",") {
		it = strings.Trim(it, " \t\n\v\f\r")
		if len(it) >= 2 && it[0] == '"' && it[len(it)-1] == '"' {
			it = it[1 : len(it)-1]
		}
		if it != "" {
			items = append(items, it)
		}
	}
	return items
}

var keyLine = regexp.MustCompile(`^([A-Za-z0-9_.-]*):`)

// Keys are the keys the file sets, in order and once each: what stands before
// the colon of a line that starts with `[A-Za-z0-9_.-]*:` (the sed of
// jig_config_unknown).
func (c *Cfg) Keys() []string {
	seen := map[string]bool{}
	keys := []string{}
	for _, line := range c.lines {
		if m := keyLine.FindStringSubmatch(line); m != nil && !seen[m[1]] {
			seen[m[1]] = true
			keys = append(keys, m[1])
		}
	}
	return keys
}
