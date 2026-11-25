---
id: adr-20261125-verify-ends-the-processes-it-started
type: adr
status: accepted
date: 2026-11-25
domains: []
paths:
  - scripts/lib/verify.sh
  - scripts/lib/profile.sh
  - scripts/lib/runenv.sh
summary: Why jig verify marks what it starts in a container with an inherited JIG_VERIFY_RUN token, ends its own run's processes when interrupted and a dead run's at the next start, and never ends a process by name, pattern or user.
---
# jig verify ends, in the project's environment, only the processes carrying a token it made

## Context

`jig verify` runs a containerised project's checks through a prefix (`docker exec -i …`,
`docker compose exec -T …`; adr-20261001-checks-run-where-the-project-runs). When the run is
interrupted — an agent's harness stops the background command, Ctrl-C, SIGTERM, SIGKILL — the
`docker exec` client on the host dies, and what it started in the container goes on: `docker exec`
without a TTY forwards no signal. `artisan test`, phpunit and paratest's workers keep the memory and
the test database, their output goes nowhere, and the next run is slow or red. On ShipRelay, where
two projects share one Devilbox `php` container, agents answered with a ritual: find the pids in
the container and `kill` them one by one, never by pattern, which would hit the other project's run.

## Decision

1. A run whose checks go through a prefix makes a token `<host-id>-<host-pid>-<random>` (`<host-id>` from `uname -n`) and hands it, as
   `JIG_VERIFY_RUN_TOKEN`, only to profiles that receive `JIG_RUN_EXEC` (the `environment`
   capability). `jp_exec` runs the command as `env JIG_VERIFY_RUN=<token> <cmd…>` inside the
   prefix, so every process of the tree inherits it — workers reparented to PID 1 included. jig's
   own environment never carries it.
2. An interrupted run ends, from its exit path, the processes in the environment whose
   `/proc/<pid>/environ` holds exactly `JIG_VERIFY_RUN=<its token>`: `TERM`, then `KILL` to what is
   left two seconds later — well inside the signal supervisor's own grace (`JIG_TERM_GRACE`), and
   after the run's records are released, so a cleanup cut short leaves no record behind.
3. A run that starts, after taking its records, lists the tokens present in the environment and,
   for each whose `<host-id>` is this machine's and whose host pid answers neither `kill -0` nor `ps -p` (a live process of another user refuses
   `kill -0` and is still alive), ends that token's processes
   the same way: SIGKILL leaves no exit path, so only a later run can clean up.
4. It never ends a process by name, pattern or user, never one whose environment it cannot read,
   and never one carrying a live run's token. Nothing in it fails `jig verify` or changes its exit
   code. This is a destructive operation and is named in `RULES.md`.

## Alternatives

- **A pid file and a walk of the children by parent pid.** paratest's workers are reparented to
  PID 1 when their parent dies; the walk loses exactly them. A variable in the environment is
  inherited by the whole tree.
- **A process group (`kill -- -<pgid>`, `setsid`).** Whether `docker exec` without a TTY makes the
  process a group leader is not established, and `setsid`, `pkill`, `ps` are missing from slim
  images. The sweep needs `sh`, `tr`, `grep`, `sed`, `sort`, `sleep` and `kill`.
- **`docker exec -t`.** A TTY forwards signals but changes the output (carriage returns, colour)
  every profile parses, and does nothing against SIGKILL.
- **Ending processes by name (`pkill -f artisan`).** Hits another project's run in a shared
  container.
- **Only reporting the leftovers.** Leaves the manual ritual in place; the person chose ending them
  at the gate.

## Consequences

- A leftover is ended by the interrupted run itself, or by the next run in the same environment.
- A process running as another user, whose `environ` cannot be read, stays — no escalation.
- A host pid reused by a live process keeps a dead run's leftovers alive: the safe side.
- Checks run on the host are unchanged: there a signal reaches the children.
- A token of another host — a jig in a devcontainer beside one on the host, two machines on one
  `DOCKER_HOST` — is never judged dead here: a pid means nothing outside its own namespace.
- The token's pid is the outer `jig verify` process; if only that is SIGKILLed while its job lives
  on, the next run ends the job's container processes, as it already reads that run's records as stale.
- The tests that read `/proc` run on Linux only (macOS and Git Bash skip them); each gives itself a
  host id of its own (`JIG_VERIFY_RUN_HOST`, a test seam), so a parallel test's sweep never ends
  another's processes.
