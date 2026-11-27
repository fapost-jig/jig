package core

import (
	"strconv"
	"strings"

	"github.com/fapost-jig/jig/next/go/internal/clock"
	"github.com/fapost-jig/jig/next/go/internal/storage"
)

// CheckoutRecord is jig_checkout_record, which the dispatcher runs before a
// command: it writes down that a session is working in this checkout
// (adr-20260924-a-checkout-records-what-is-happening-in-it). words is the
// command word and its arguments. It prints nothing and nothing in it may fail
// the command.
func CheckoutRecord(ctx Ctx, words []string) {
	if ctx.Env("JIG_INTERNAL_REDRAW") != "" {
		return
	}
	p, ok := checkoutProject(ctx)
	if !ok {
		return
	}
	runtime := storage.RuntimeDir(p.Root)
	if !storage.MakeDir(runtime) {
		return
	}
	head := checkoutHead(ctx, p)

	// The checkout's own record; `branch_reported` is carried over untouched.
	body := "command: " + strings.Join(words, " ") + "\n"
	if told, _ := storage.RecordGet(runtime+"/checkout", "branch_reported"); told != "" {
		body += "branch_reported: " + told + "\n"
	}
	storage.WriteRecord(runtime+"/checkout", body)

	checkoutTake(ctx, p, words)
	checkoutRevive(ctx, p)

	name := checkoutName(ctx, p, head, words)
	if name == "" || !storage.ValidID(name) {
		return
	}
	file, err := storage.WorkingRecordPath(p.Root, name)
	if err != nil || !storage.MakeDir(runtime+"/working") {
		return
	}
	cmd := oneLine(strings.Join(words, " "), "\n", "\r")
	body = "command: " + cmd + "\n"
	if session := checkoutSession(ctx, p); session != "" && session != name {
		body += "session: " + session + "\n"
	}
	storage.WriteRecord(file, body)
}

// oneLine replaces each of the characters in s by a space.
func oneLine(s string, chars ...string) string {
	for _, c := range chars {
		s = strings.ReplaceAll(s, c, " ")
	}
	return s
}

// checkoutProject is _jig_checkout_ready: quiet where jig_require_init would
// complain, and the root is always computed, never taken from the environment.
func checkoutProject(ctx Ctx) (Project, bool) {
	top, ok := gitTop(ctx)
	if !ok {
		return Project{}, false
	}
	root := storage.PhysicalDir(top)
	if root == "" || !storage.HasConfig(root) {
		return Project{}, false
	}
	return Project{Root: root}, true
}

// checkoutHead is _jig_checkout_head: the branch checked out, "" when detached.
func checkoutHead(ctx Ctx, p Project) string {
	r, err := ctx.Exec.Git(p.Root, "symbolic-ref", "--quiet", "--short", "HEAD")
	if err != nil || r.Code != 0 {
		return ""
	}
	return strings.TrimRight(r.Stdout, "\n")
}

// checkoutName is the name of the work in progress: a task named by the
// arguments, else the task whose branch is checked out, else the session.
func checkoutName(ctx Ctx, p Project, head string, words []string) string {
	if n := checkoutNameFromArgs(ctx, p, head, words); n != "" {
		return n
	}
	if n := checkoutNameFromHead(p, head); n != "" {
		return n
	}
	return checkoutSession(ctx, p)
}

// checkoutNameFromArgs is _jig_checkout_name_from_args: the first argument that
// is a task id with a workspace, unless its branch is checked out elsewhere.
func checkoutNameFromArgs(ctx Ctx, p Project, head string, words []string) string {
	list, listed := "", false
	for _, a := range words {
		if strings.HasPrefix(a, "-") || !storage.ValidID(a) || !storage.TaskHasState(p.Root, a) {
			continue
		}
		if !listed {
			listed = true
			if r, err := ctx.Exec.Git(p.Root, "worktree", "list", "--porcelain"); err == nil && r.Code == 0 {
				list = r.Stdout
			}
		}
		if taskElsewhere(p, a, head, list) {
			continue
		}
		return a
	}
	return ""
}

// taskElsewhere is _jig_checkout_task_elsewhere: the task's branch is checked
// out in a worktree that is not this one.
func taskElsewhere(p Project, id, head, list string) bool {
	state, err := storage.TaskStatePath(p.Root, id)
	if err != nil {
		return false
	}
	branch, _ := storage.RecordGet(state, "branch")
	if branch == "" || list == "" || branch == head {
		return false
	}
	return strings.Contains("\n"+list+"\n", "\nbranch refs/heads/"+branch+"\n")
}

// checkoutNameFromHead is _jig_checkout_name_from_head: the first task whose
// branch is HEAD and which is active or ready.
func checkoutNameFromHead(p Project, head string) string {
	if head == "" {
		return ""
	}
	for _, id := range storage.TaskIDsWithState(p.Root) {
		state, err := storage.TaskStatePath(p.Root, id)
		if err != nil {
			continue
		}
		if br, _ := storage.RecordGet(state, "branch"); br != head {
			continue
		}
		if st, _ := storage.RecordGet(state, "status"); st == "active" || st == "ready" {
			return id
		}
	}
	return ""
}

// checkoutSession is jig_checkout_session: the runtime's id for the session
// running this command, "" when it has none. The adapters are found in the
// framework source, as init and upgrade find them; only the claude adapter
// names a session (CLAUDE_CODE_SESSION_ID), codex answers none.
func checkoutSession(ctx Ctx, p Project) string {
	dir := adaptersDir(ctx, p)
	if dir == "" {
		return ""
	}
	adapters := storage.CfgLayered(p.Root, "adapters", false, "claude codex")
	for _, a := range cfgWords(adapters) {
		if !validAdapterName(a) || !storage.IsFile(dir+"/"+a+"/adapter.sh") {
			continue
		}
		if a != "claude" {
			continue
		}
		id := ctx.Env("CLAUDE_CODE_SESSION_ID")
		if id == "" || !storage.ValidID(id) {
			continue
		}
		return id
	}
	return ""
}

// adaptersDir is _jig_checkout_adapters_dir: the adapters directory of the
// framework source the manifest records, else of the source this program
// belongs to.
func adaptersDir(ctx Ctx, p Project) string {
	src := storage.ManifestHeader(p.Root, "jig.source")
	switch src {
	case ".":
		src = p.Root
	case "global":
		src = ""
	}
	if src != "" && storage.IsDir(src+"/adapters") {
		return src + "/adapters"
	}
	for _, cand := range []string{ctx.Root, ctx.Env("JIG_SOURCE")} {
		if cand != "" && storage.IsSourceRoot(cand) {
			if storage.IsDir(cand + "/adapters") {
				return cand + "/adapters"
			}
			return ""
		}
	}
	return ""
}

// cfgWords is cfg_list: brackets dropped, commas as blanks, the words.
func cfgWords(v string) []string {
	v = strings.NewReplacer("[", "", "]", "", ",", " ").Replace(v)
	return strings.Fields(v)
}

// validAdapterName is _adapters_valid_name.
func validAdapterName(n string) bool {
	if n == "" || !(n[0] >= 'A' && n[0] <= 'Z' || n[0] >= 'a' && n[0] <= 'z' || n[0] >= '0' && n[0] <= '9') {
		return false
	}
	for i := 0; i < len(n); i++ {
		c := n[i]
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// checkoutWorks is _jig_checkout_works for the `context` command: the first
// argument that is a task id with a workspace.
func checkoutWorks(p Project, words []string) string {
	if len(words) == 0 || words[0] != "context" {
		return ""
	}
	for _, a := range words[1:] {
		if strings.HasPrefix(a, "-") || !storage.ValidID(a) || !storage.TaskHasState(p.Root, a) {
			continue
		}
		return a
	}
	return ""
}

// checkoutTTL is _jig_checkout_ttl: how long a record counts as a live
// session, in seconds; a setting that is not a duration gives the default.
func checkoutTTL(p Project) int64 {
	raw := storage.CfgLayered(p.Root, "checkout.busy_ttl", true, "12h")
	n, unit := raw, ""
	if l := len(raw); l > 0 && strings.ContainsRune("dhms", rune(raw[l-1])) {
		n, unit = raw[:l-1], raw[l-1:]
	}
	secs, err := strconv.ParseInt(n, 10, 64)
	if err != nil || n == "" || strings.Trim(n, "0123456789") != "" {
		return 43200
	}
	switch unit {
	case "", "d":
		return secs * 86400
	case "h":
		return secs * 3600
	case "m":
		return secs * 60
	}
	return secs
}

// checkoutTake is _jig_checkout_take: this session's record for the task the
// command works on, in the clone's main checkout.
func checkoutTake(ctx Ctx, p Project, words []string) {
	id := checkoutWorks(p, words)
	if id == "" {
		return
	}
	session := checkoutSession(ctx, p)
	if session == "" {
		return
	}
	root := storage.CloneRoot(p.Root)
	file, err := storage.TakenRecordPath(root, id, session)
	if err != nil || !storage.MakeDir(file[:strings.LastIndex(file, "/")]) {
		return
	}
	since := ""
	if v, ok := storage.RecordGet(file, "since"); ok {
		since = v
		mtime, got := storage.MTime(file)
		// real clock: against a file mtime
		if !got || ctx.FileClock.Now().Unix()-mtime > checkoutTTL(p) {
			since = ""
		}
	}
	if since == "" {
		since = ctx.Clock.UTC()
	}
	cmd := oneLine(strings.Join(words, " "), "\n", "\t")
	if !storage.WriteRecord(file, "checkout: "+p.Root+"\nsince: "+since+"\ncommand: "+cmd+"\n") {
		return
	}
	recordChanged(p, ctx.Clock)
}

// checkoutRevive is _jig_checkout_revive: a session that goes on after its end
// was marked takes the mark off its own taken records.
func checkoutRevive(ctx Ctx, p Project) {
	session := checkoutSession(ctx, p)
	if session == "" {
		return
	}
	for _, f := range storage.TakenRecordsOf(storage.CloneRoot(p.Root), session) {
		if _, ended := storage.RecordGet(f, "ended"); !ended {
			continue
		}
		if body, ok := storage.RecordDropKey(f, "ended"); ok {
			storage.WriteRecord(f, body)
		}
		recordChanged(p, ctx.Clock)
	}
}

// recordChanged is jig_record_changed for a record a read reports: the clone's
// revision is raised. A failure is not the command's.
func recordChanged(p Project, clk clock.Clock) {
	_ = storage.RevisionBump(p.Root, clk)
}
