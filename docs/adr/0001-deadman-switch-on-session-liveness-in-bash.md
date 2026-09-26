# ADR 0001: A deadman switch on the operator's session, written in bash

## Status

Accepted. 2026-09-23. The consequences section records two exposures found
while writing this, one measured and one that a test caught red. The second
was fixed the same day, by `126d7e6`, and the consequences say so.

## Context

The job is one sentence: let someone change a remote host's network or
firewall configuration without the change being able to strand them.

Three constraints from the environment this has to work in, and they do most
of the deciding:

- At the moment you need the rollback, you cannot install anything. The box is
  a minimal VPS image, a container, or firmware with a shell in it. The
  recovery path has to be made of what is already there.
- The failure to detect is "I can no longer reach this machine", which is not
  the same event as "this machine is unhealthy". sshd can be listening on an
  address nobody outside your own network can reach.
- The automatic action is destructive, so it has to be cancellable by the one
  person who knows whether the change is good: the one who is locked out and
  therefore cannot type anything.

## Decision

Key the switch on the liveness of the operator's own login session, and count
down against a wall-clock deadline as a backstop.

`pick_probe` in `bin/deadman-ssh` records a tuple while the session is
definitely up: `SSH_CONNECTION` gives the local and peer endpoints, and the
tuple is only kept if `socket_state` can find that exact pair in
`ss -Htn state established` at that moment. A probe that cannot be verified at
arm time is dropped rather than trusted, and the session falls back to the
`DM_SESSION_PID` probe or to the timer. The detached `watch` process then
re-reads the state file every `--interval` seconds: `confirm` stops it, the
deadline fires it, and a session that has been unreadable for `--grace`
seconds moves the deadline forward.

Rollback is a directory of ordered executables, `hooks.d/`, that the switch
knows nothing about. Every hook gets `save <dir>` at arm time; every hook that
returned 0 gets `restore <dir>` later, newest first, and a hook that failed or
skipped at capture is never asked to restore. If a capture fails, the arm
aborts, restores what it had already taken, and your change is never attempted
(`abort_failed_arm`). The state that makes this survivable is on disk in one
directory per session, including the boot id, because the process that needs
it after a reboot shares no memory with the one that armed it.

Keep the whole thing in bash 4 plus coreutils, `awk`, `sed`, `grep` and
`setsid`. Nothing else.

## Why not a cron healthcheck

The obvious alternative is a timer that probes something and reverts after N
failures. It is rejected for four reasons, and the first one is the real one.

**A healthcheck answers a different question.** A probe running on the box
tests whether the box can reach whatever it probes. Locked-out is not the same
as broken: after a bad ruleset the box is often perfectly healthy and
unreachable only from the one place you are sitting. To detect that, the probe
has to come from outside, which means a second machine, credentials to it, a
route from it, and a policy about who is allowed to revert what. That
infrastructure has to be standing before you make the change, and the thing
most likely to have just failed is the network path to it.

Session liveness is the same signal without the second machine. It is measured
on the box, at the socket that carries your own session, and its absence means
exactly one thing: the person working on this box stopped seeing it.

**Granularity runs the wrong way.** A minute-granular cron gives you a
recovery time of one period plus N failures, so minutes at best, and shortening
it means a probe that trips on one lost packet. The switch here polls every 2
seconds and gives you `--grace` on top of an event it is watching for.

**An always-watching system needs its own arming story.** A timer that can
rewrite configuration is armed all the time, so it needs a lockout guard, an
operator presence check, or a rule about when it is allowed to act. You end up
building a deadman switch on top of the healthcheck. Keying on a session gives
the arming for free: the session exists precisely while somebody is working.

**What the cron version would have won.** A real healthcheck can test the
service the change was for, not just the path back to the operator: curl the
application, check the route is propagating, confirm DNS still resolves. This
switch cannot tell a working box from a broken-but-reachable one. If the
change takes the web service down while SSH stays up, this tool waits for you
to notice, and you have exactly the TTL you armed with to notice in. That is
the property given up, deliberately, in exchange for needing no outside
observer.

## Why bash and not Python

Python 3 is on most of the boxes this runs on. "Most" is the problem: the
rollback is the one code path that must work on a machine where you cannot add
a package, and bash plus coreutils is the floor below which nothing with a
shell falls. Python would buy dictionaries, exceptions, and a module system in
exchange for that dependency, and none of the three is doing work here. The
state is a `key=value` file, the hooks are a directory read in name order, and
the logic is two comparisons and a sleep.

There is a second reason that only shows up once you have written the hook
contract: bash is already the language the extension point is in. Every hook
an operator writes is a shell script wrapping `nft`, `ip` and `sysctl`. Had the
switch been Python, hooks would be shell scripts launched from Python, and
every value passed to them crosses a serialization boundary.

The costs, named rather than argued away:

- **Process boundaries are invisible.** A shell variable's visibility in a
  child process depends on whether something happened to `export` it, and
  nothing at the call site says so. This produced a real defect: `DEADMAN_LIB`
  was exported by `cmd_arm` and nowhere else, so a hook run by an operator's
  `rollback` or by a watchdog that `recover` restarted could not source the
  library it needs for `dm_priv`. In Python the same design passes a context to
  the hook runner and a missing field is an error at the call rather than a
  rollback that fails at 3 a.m. The suite caught it and left it red. The
  fixture `40-libseen` asserts the guarantee from three processes, two of those
  checks failed, and the fix changes behaviour, so it was reported rather than
  worked around. `126d7e6` moved the export from `cmd_arm` into `run_hook`, the
  only place a hook is invoked, so it happens at the call in whichever process
  reached it, and added the `recover` reboot check nothing had covered.
  Deriving the library path from the hook's own location, as `20-nftables`
  does, survives as a fallback.
- **Error handling is a discipline, not a mechanism.** `set -euo pipefail` plus
  deliberate `|| rc=$?` at the places that must keep going (`run_hook`,
  `do_rollback`) is the whole story, and one missing `|| rc=$?` turns a
  continued rollback into an aborted one.
- **No lint ran here when this was decided.** `shellcheck` was not installed
  and could not be installed without root, so quoting and word-splitting bugs
  of exactly the class shellcheck exists to catch were unverified locally, and
  `bash -n` checked syntax and nothing else. That is no longer the state of the
  evidence. GitHub Actions has run the lint job on 0.9.0 from apt, on every
  push to `main` through 2026-09-26 and on one Dependabot PR. The job's gate is
  `--severity=error` and has failed no build; what went red was this suite's
  own warning-level check, `FAIL shellcheck: run.sh` on SC2155, in runs
  `35934781246` (`main` at `bccca9b`) and `35934864372`. The job's non-fatal
  warning report printed the same finding beside them, and both checks were
  green from `36256468976` after `8a5f27d` moved the assignment out of the
  `local`. Locally, 0.11.0 taken out of the `koalaman/shellcheck:stable` image
  and put on `PATH` by hand reports nothing at `--severity=warning` across the
  eleven files the lint job's loop lists. What has not changed: no package
  installs here, and a local lint still rests on a binary placed by hand.
- **The harness is hand-rolled.** No bats, no pytest, so ordering assertions
  ("beta restored before alpha") are grep on a trace file with line numbers.
  Cheap, but it has none of the structure a test framework would give.

## What rollback guarantees

Read as a contract, and nothing beyond it:

- State captured by a hook is handed back to that hook, newest capture first.
- A hook that did not capture cleanly is never run at restore time, so no hook
  restores from a snapshot it did not write.
- Nothing is attempted if any capture failed: the change you asked for does not
  run, the captures that did succeed are put back, and the arm exits 1.
- One operator can stop it at any time before the deadline, from the box, with
  `confirm`.
- Every action is in `$XDG_STATE_HOME/deadman-ssh/sessions/<id>/log`, and the
  reason a rollback fired is in the `ROLLED_BACK` marker next to it.

## What it cannot guarantee

- **That "restore" is the inverse of your change.** A hook puts back what it
  captured. The nftables hook reloads the ruleset; a route your change added
  outside that ruleset is not in the snapshot and survives the rollback.
- **That your session going away means the box is unreachable.** A ruleset that
  silently drops your traffic leaves the server-side socket `ESTABLISHED`, so
  the probe keeps reporting the session as present. The TTL is what saves you
  there. See the first bullet of *What is not protected against* in the README.
- **That the watchdog is still running.** `setsid` detaches the session, not
  the cgroup: measured here, the detached watchdog stayed in the login
  session's `session-N.scope`, where `KillUserProcesses=yes` can take it with
  the session. Outliving the login session needs a unit, which needs root or a
  configuration change, so it is not in this tool.
- **Atomicity.** A rollback whose hook fails sets `rollback-failed`, names the
  hook, and exits 1 with the host in a mixed state. `recover` retries it, and
  that is the whole of the story: there is no transaction.
- **That the state directory survived.** Snapshots live on the disk of the box
  they restore.
- **Safety against your own typo.** `confirm` is taken at face value.

## Open questions

- A route or interface hook would make the tool useful for changes other than
  firewalls. `hooks.d` is the seam; the switch itself needs nothing.
- The watchdog's own liveness is asserted nowhere. A `--probe-only` mode or a
  second timer that notices a missing watchdog would close the same gap from
  the other side.
