# deadman-ssh

A dead man's switch for remote administration. Arm it on a host before a
change that can cut the branch you are sitting on, and it restores the state
captured at arm time if you do not come back.

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

You are three hundred miles from a server and about to rewrite its firewall.
If the new ruleset drops your own SSH traffic, you do not find out by typing,
you find out by not getting an answer. Rebooting into a rescue system is the
usual recovery, and it is an outage you scheduled yourself. A deadman switch
takes that decision away: the box puts its own configuration back without
being asked, either when the countdown runs out or when the session you were
working from disappears and stays gone through the grace period.

The design constraint is that you must be able to stop it. A rollback you
cannot cancel is a worse hazard than the change it protects, because you now
have two ways to lose the box. Every command here other than `arm` exists to
stop, delay or inspect a switch that is already running.

## Table of Contents

- [How it decides](#how-it-decides)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Writing a hook](#writing-a-hook)
- [Exit codes](#exit-codes)
- [Testing](#testing)
- [Limitations](#limitations)
- [License](#license)

## How it decides

```
 arm
  |   every hook runs `save <dir>`, lowest name first
  |   a hook that fails its capture aborts the arm: what was
  |   already captured gets restored, the change is never run
  v
 watchdog        detached, polling every --interval, deadline at now+--ttl
  |
  +----------------+----------------------------+
  |                |                            |
  v                v                            v
 confirm      deadline passed        probe cannot see the session
 you typed    nobody typed           socket gone, pid gone
  |                |                            |
  v                v                            v
 stands       rollback                 --grace seconds pass
 down               ^                  still not seeing it,
  |                 |                  so the deadline moves
  v                 |                  in front of the TTL
 change stays       |                            |
                    +<---------------------------+
                    |
                    +-- every captured hook restored
                    |     state=rolled-back, exit 4
                    +-- a hook failed
                          state=rollback-failed, exit 1,
                          the host may be in a mixed state
```

The countdown is the backstop. The probe is what makes it fire early when the
session you are working from actually leaves the socket table, which is the
case worth detecting in a hurry. Where there is no probe at all, `arm` says so
and only the TTL can fire it. What a probe cannot see, including the drop rule
that is the reason most people want this tool, is under
[What is not protected against](#what-is-not-protected-against).

Three rules hold everywhere in the code:

- An unreadable probe is a live session. A switch that guesses "gone" when it
  cannot read rolls back a working host, which is the worse of the two errors.
- Only hooks whose `save` returned 0 get a `restore`. Nothing is restored from
  a snapshot that was never taken.
- Rollback runs newest captured hook first, and a failing hook does not stop
  the ones after it.

## Requirements

- bash 4 or newer (`local -a`, `mapfile`, `${var^^}`).
- coreutils, `awk`, `sed`, `grep`, and `setsid` from util-linux.
- `iproute2` for `ss`, only for the socket probe. Without it the switch falls
  back to the timer, it does not fail.
- root or sudo only when a hook needs it. The switch itself never escalates.
  Dry-run needs neither.

`nft` is only needed by the hook that ships here. Run that hook on a box
without nftables and it exits 77, which the switch records as a skip.

## Installation

From a clean checkout, with `~/.local/bin` on `PATH`:

```bash
mkdir -p ~/.local/bin
ln -s "$PWD/bin/deadman-ssh" ~/.local/bin/deadman-ssh
DEADMAN_DRY_RUN=1 deadman-ssh hooks
```

The last line lists the hooks that would run and prints the directory they
were read from. It touches nothing. Copy the tree instead of symlinking it if
you prefer; `lib/` and `hooks.d/` have to stay next to the script, or
`DEADMAN_LIB` and `DEADMAN_HOOKS_DIR` have to say where they went.

State lives in `$XDG_STATE_HOME/deadman-ssh`, defaulting to
`~/.local/state/deadman-ssh`. One directory per session, holding the state
file, the snapshots, the watchdog pid and the watchdog log.

## Usage

The short TTL is on purpose. 300 seconds is enough to verify a ruleset from a
second machine and short enough that an abandoned session restores itself
before you notice it is gone.

### Arm before a risky change

```bash
deadman-ssh arm --ttl 5m
# capture lines, then: "Make the change in this shell now."
nft -f /tmp/new-rules.nft
```

Or hand the change to the switch and let it judge the exit status:

```bash
deadman-ssh arm --ttl 5m -- nft -f /tmp/new-rules.nft
```

A non-zero exit from the change rolls back at once, with reason
`payload-failed`, rather than waiting out the TTL. The change is run as an
argv list, not through a shell: `&&`, `|` and `>` reach the command as
arguments. Say so explicitly if you want a shell:

```bash
deadman-ssh arm --ttl 5m -- sh -c 'nft -f /tmp/new.nft && nft list ruleset'
```

### Confirm

```bash
deadman-ssh confirm
```

Writes a marker file. The watchdog notices it within its poll interval and
stands down without restoring anything. The snapshots stay until you purge
them.

### Extend

Still working, still reachable, and the five minutes are nearly up:

```bash
deadman-ssh extend --ttl 10m
```

The new deadline is ten minutes from now, not from the old deadline.

### Status

```bash
deadman-ssh status
```

```
id=deploy@web-01 state=armed deadline=2026-03-04T09:12:44Z left=4m31s watchdog=17151 probe=socket 192.0.2.2:22 192.0.2.1:45455 dry_run=0
  hooks: saved=[20-nftables] requested=[20-nftables]
  armed in boot 3f1c9a2e-71b4-4a05-9c1f-6d2e88b0c1aa, this boot 3f1c9a2e-71b4-4a05-9c1f-6d2e88b0c1aa
  dir: /home/deploy/.local/state/deadman-ssh/sessions/deploy@web-01
```

Id, path and boot id are placeholders. The rest is the literal format, and the
`left=` countdown is the same formatter `recover` prints with.

No id given lists every session under the state directory. A named session
that does not exist is an error rather than an empty list, because a typo in
`--id` reading as "nothing is armed" is how you end up with two switches.

### Disarm

```bash
deadman-ssh disarm            # keep the snapshots
deadman-ssh disarm --purge    # delete the session directory
```

### Roll it back by hand

```bash
deadman-ssh rollback --reason 'new ruleset broken, reverting now'
```

Exits 4 when every captured hook restored cleanly.

### Recover

```bash
deadman-ssh recover
```

For the case where the box came back and the watchdog did not. `recover` reads
what is on disk, compares the boot id recorded at arm time with the current
one, and then does one of three things: roll back (armed in a previous boot,
never confirmed), start a new watchdog (armed this boot, deadline not passed),
or say nothing is pending. It is the only command allowed to act on a session
whose watchdog is gone, and `arm` refuses to run over one.

### A session that is not an SSH login

`SSH_CONNECTION` is what the socket probe reads. A change made from cron or
`at` has none, so point the probe at a pid instead:

```bash
DM_SESSION_PID=$$ deadman-ssh arm --ttl 5m
```

With neither, there is no probe: `arm` logs that only the TTL can fire this
rollback, and `--grace` becomes dead weight.

## Writing a hook

A hook is an executable file in the hook directory. The switch knows nothing
about what it rolls back; it only orders the calls.

```
$ deadman-ssh hooks
hook directory: /home/deploy/deadman-ssh/hooks.d
20-nftables      opts: none
```

The listing format is verbatim; the path stands for wherever the checkout is.

### Contract

```
<NN-name> save <snapshot-dir>      capture the current state, write it into <snapshot-dir>
<NN-name> restore <snapshot-dir>   put it back
exit 0    done
exit 77   nothing applicable on this host, recorded as a skip
other     failure
```

`save` runs at arm time, in filename order, lowest first. `restore` runs in
the reverse order among the hooks that captured, so the newest change is
undone before the older one it sits on. A hook skipped at `save` is never
called for `restore`, and a hook whose `save` failed aborts the arm before
your change is attempted.

The snapshot directory is `<state>/sessions/<id>/snapshots/<hook-name>/`.
It is yours, it exists before you are called, and nothing else reads it. The
hook is run as the user who armed the switch, so anything privileged goes
through `dm_priv`.

### Environment

Read these, do not set them.

| Variable | Meaning |
|---|---|
| `DEADMAN_DRY_RUN` | Print privileged actions instead of running them. |
| `DEADMAN_RUNNER` | Words used to escalate, default `sudo -n`. |
| `DEADMAN_STATE_DIR` | Where sessions live. |
| `DEADMAN_HOOKS_DIR` | The hook directory the switch is using. |
| `DEADMAN_LIB` | Directory holding `deadman-lib.sh`. |
| `DEADMAN_OPT_<KEY>` | One `--opt KEY=VALUE` from the arm, upper-cased. |

`DEADMAN_OPT_<KEY>` is exported by the process that ran `arm`. The watchdog and
a `rollback` you type later are separate processes that never saw the option,
so a hook that needs an option at restore time must write its effect into the
snapshot. That is what `50-alpha` in the fixtures is set up to prove.

`DEADMAN_LIB` reaches a hook the same way: reliably from the arm, not yet from
the other two processes. `20-nftables` survives this because it derives the
path from its own location as a fallback, and `hooks.d/` sits next to `lib/` in
a checkout. A hook installed anywhere else has to do the same, or it cannot
find `dm_priv` when it matters. Two checks in `bash tests/run.sh` are red about
this and are documented under [Limitations](#limitations).

### An example

```bash
#!/usr/bin/env bash
# 30-resolv: capture /etc/resolv.conf, put it back if the switch fires.
set -euo pipefail

DM_LIB_DIR=${DEADMAN_LIB:-$(dirname "$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")")/lib}
# shellcheck source=lib/deadman-lib.sh
. "$DM_LIB_DIR/deadman-lib.sh"

action=${1:?usage: 30-resolv save|restore <snapshot-dir>}
snap=${2:?usage: 30-resolv save|restore <snapshot-dir>}

case $action in
save)
  dm_capture "$snap/resolv.conf" cat /etc/resolv.conf
  ;;
restore)
  [[ -s $snap/resolv.conf ]] || dm_die "no snapshot in $snap"
  dm_priv_in "$snap/resolv.conf" cp /dev/stdin /etc/resolv.conf
  ;;
*)
  dm_die "unknown action '$action'"
  ;;
esac
```

Run from a checkout, with dry-run on, this is what it prints. Both lines were
produced by the block above, with the hook sitting outside the repo tree:

```
$ DEADMAN_DRY_RUN=1 deadman-ssh arm --ttl 5m --hook 30-resolv
2026-03-04T09:00:00Z DRY-RUN capture resolv.conf <= cat /etc/resolv.conf
2026-03-04T09:00:00Z hook 30-resolv: save ok
2026-03-04T09:00:00Z watchdog started (pid 17151)
2026-03-04T09:00:00Z arm: armed. Make the change in this shell now.

$ DEADMAN_DRY_RUN=1 deadman-ssh rollback --reason reviewed
2026-03-04T09:01:00Z rollback[reviewed]: 1 hook(s) to restore, newest first
2026-03-04T09:01:00Z DRY-RUN cp /dev/stdin /etc/resolv.conf < .../snapshots/30-resolv/resolv.conf
2026-03-04T09:01:00Z hook 30-resolv: restore ok
2026-03-04T09:01:00Z rollback[reviewed]: complete
$ echo $?
4
```

Timestamps and paths stand in for the real ones; the wording is the tool's.
Note that the restore branch does not redirect the helper's output anywhere: a
`>/dev/null` on `dm_priv_in` also swallows the DRY-RUN line, which is the only
thing that tells you what a dry-run rollback would have done.

### Helpers a hook is meant to call

Everything in `lib/deadman-lib.sh` is available by sourcing it. The two that
exist only for hook authors:

`dm_priv_in <file> <command> [args...]` runs a command with `<file>` on stdin,
through the escalator. `dm_priv` cannot express this: its argv is assembled
word for word, so a trailing `<` reaches `sudo` as an argument rather than as a
redirection. Use it when the tool you are restoring takes the state on stdin
(`cp /dev/stdin <target>`, `tee <target>`). It is also the form that keeps the
snapshot inside the escalated process instead of handing the escalator a shell
string to parse. Dry-run prints the command and the file it would have read.

`dm_capture_field <file> <n>` prints field `n` of the first line of a
snapshot. Snapshots are written by `dm_capture`, which in dry-run mode stores
`DRYRUN <command>` instead of output that no command produced, so asking a
dry-run snapshot for a value has no answer. The helper returns a marker rather
than an empty string: `<from-snapshot>` for a dry-run placeholder,
`<empty-snapshot>` for a file with nothing in it. A hook that logs what it is
about to restore gets a readable line out of both, instead of restoring a
blank.

The rest, briefly:

- `dm_capture <file> <command> [args...]` records a read-only query.
- `dm_priv <command> [args...]` is the only path to the host that escalates.
- `dm_require_cmd <cmd>...` exits 77 for you when a tool is not installed.
- `dm_die`, `dm_log`, `dm_warn` for output; `dm_is_dry_run`, `dm_quote`.

Two conventions worth copying from `20-nftables`: refuse to touch live state
when the snapshot file is missing, and treat an empty capture as a real
state rather than as nothing to do. A host whose ruleset was empty before your
change has to be flushed back to empty, which is the difference between a
rollback and a reconciliation.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | ok |
| 1 | failure, including a rollback where a hook failed |
| 2 | usage error, nothing armed |
| 3 | refused, the session is already armed or is no longer armed |
| 4 | rollback completed |

## Testing

```bash
bash tests/run.sh
```

24 groups, 194 checks, about 26 seconds: 192 pass, 2 fail, 1 skipped. Plain
bash and coreutils: the
box you administer has neither bats nor pytest, and a switch that can only be
tested on a developer machine is not testable where it runs. `bats` is not
installed here and is not used, which is a deliberate deviation from the plan
this repo came out of: a second scripting language would be a dependency the
tool itself does not need. The skipped check is `shellcheck`, which this
machine does not have and cannot install.

The harness runs the real CLI with `DEADMAN_DRY_RUN=1`, a scratch state
directory under `$TMPDIR`, `hooks.d` pointed at fixtures, `DEADMAN_RUNNER`
pinned to `false`, and a fake `ss` earlier on `PATH`. Three groups turn dry-run
off, because dry-run is what would hide the answer there: a change that fails,
a capture that fails, a capture that is interrupted mid-arm. Those use fixture
hooks that write only inside the scratch directory and payloads of `false` or
`touch`. Nothing in the suite calls `nft`, `ip`, `iptables`, `tc` or
`systemctl`, and the only processes ever signalled are watchdogs this harness
started and checked against `/proc/<pid>/cmdline` first. One group runs the
host's own `ss`, read-only, to check that a session it cannot match degrades to
the timer; it passes whichever way that goes.

Two checks are red, in the group `DEADMAN_LIB reaches a hook in every process
that runs one`:

```
  FAIL a rollback from a second process exits 4: expected rc 4, got 1
  FAIL and the hook found the library there: output did not contain: hook 40-libseen: restore ok
```

They are left red rather than fixed, because the defect they name is in the
switch and the fix changes behaviour. `DEADMAN_LIB` is exported by `cmd_arm`
and by nothing else, so a hook that cannot derive the library from its own
location fails at restore, which is the one moment it matters. A watchdog
started by `recover` has the same problem, and no test covers it. Details under
[Limitations](#limitations).

## Limitations

This section is the state of the evidence, not a disclaimer. Read it before
trusting the switch on a box you care about.

### Exercised by the suite

Argument validation, help, hook listing, capture ordering, `--opt` reaching a
hook, expiry rolling back newest-first, confirm standing the watchdog down,
extend moving a deadline, double arm refused with exit 3, disarm and purge, a
hook skipped with 77 never restored, a failing capture aborting the arm before
the change, a signal during capture restoring what was taken, a non-zero
change rolling back at once, a dead pid probe cutting the deadline, both
iproute2 column layouts read through the fake `ss`, a socket disappearing
mid-run, an unreadable socket table *not* firing the rollback, a refused
IPv6 tuple degrading to the timer instead of reading as gone, the dry-run plan
printed for the shipped nftables hook, and `recover` after a simulated reboot
including restarting a watchdog.

### Not exercised, and what each one would prove

| Behaviour | Why it is untested here |
|---|---|
| `nft flush ruleset` then `nft -f <snapshot>` actually restoring a ruleset | Needs root and a machine whose ruleset you can afford to reload. Dry-run proves the plan, never the result. |
| `ss` column layout on a live host | The two layouts tested are the two iproute2 has printed for `ss -Htn state established`, reproduced against a fake. Which one your box prints is not known from here. |
| `setsid nohup` surviving session teardown | See the cgroup finding below. |
| `/proc/<pid>/cmdline` matching under pid reuse | `watchdog_matches` is what a stale pid file is checked against, and the harness verifies it, but no test races a pid recycle against it. |
| `--grace` cutting a live deadline in the field | The mechanism is tested against a dead pid and a disappearing fake socket. Real timing, under a real disconnect, is not. |
| IPv6 `SSH_CONNECTION` on a host that only has v6 | The tuple is refused by design, which leaves a v6-only operator on the timer with no early detection. Tested as a refusal, not as a working probe. |
| Rollback after a reboot with an escalated runner | `recover` is tested with `DEADMAN_RUNNER=false` and dry-run on. The real version needs sudo to still work unattended after a boot. |
| Two operators arming the same id | The mkdir lock makes the second arm lose, which is tested for one process at a time. Nothing here proves it against a genuine race. |
| Concurrent rollback from `watch` and `recover` | Both check for a `ROLLED_BACK` marker before firing. That guard is read from the code, not from a test that runs them against each other. |
| `shellcheck` | Not installed on this machine and not installable without root. The lint gate exists in CI and has never run anything here. `bash -n` passes on every file, and `bash -n` is a syntax check only. |
| GitHub Actions | `.github/workflows/ci.yml` has never been executed by GitHub. |

### Known defect: the library does not reach every process that runs a hook

`DEADMAN_LIB` is exported inside `cmd_arm` and nowhere else, so the three
processes that invoke a hook are not equivalent:

| Process | Hook can source the library |
|---|---|
| `arm` | yes, it exports the variable |
| `watch` started by that arm | yes, by inheritance from the arm |
| `rollback` typed by an operator | no |
| `watch` started by `recover` | no |

The last row is the one that matters: after a reboot the arm is long gone, and
the watchdog `recover` starts is the process that performs the restore. A hook
that sits in `hooks.d` next to `lib` is fine, because it derives the path from
its own location. A hook in a directory of your own, which is what
`DEADMAN_HOOKS_DIR` is for, gets `DEADMAN_LIB` empty and sources nothing. The
two red checks in `Testing` reproduce the `rollback` row; nothing reproduces
the `recover` row yet.

The fix is one line, exporting the variable where a hook is about to be run
rather than where the arm happened to be, and it is not in this pass because
exporting it changes behaviour and the change should be reviewed on its own
merit, not smuggled in with documentation.

### What is not protected against

- **The failure the socket probe was built for, mostly.** A ruleset that
  silently drops your traffic does not send a FIN or an RST, so the
  server-side socket stays `ESTABLISHED` in the kernel and `ss` keeps listing
  it. The probe reads the session as present and the early rollback never
  happens. The socket disappears when sshd is killed or the host reboots, and
  when the client sends a proper close: those are real cases, but "I locked
  myself out with a drop rule" is not one of them. What protects you there is
  the TTL, so arm with the countdown you can actually afford to sit through,
  and verify from a second machine or the serial console before you confirm.
  One exception, and it is the reason to configure it: if `sshd` has
  `ClientAliveInterval` and `ClientAliveCountMax` set, an unresponsive client
  is disconnected after the two multiplied together, the socket leaves the
  table, and the probe does see the loss
  ([sshd_config(5)](https://man.openbsd.org/sshd_config.5)). This is an
  argument from how TCP keeps a socket plus what that page says sshd does, not
  a measurement: a test for it needs a host whose traffic I can drop, which is
  not this machine.
- **A watchdog killed with the login session.** `setsid` puts the process in a
  new session and a new process group, but not in a new cgroup. Measured on the
  host this was written on, a child started by `setsid nohup` stayed in
  `user.slice/user-1000.slice/session-1.scope`, the same scope as its parent.
  Where `logind` has `KillUserProcesses=yes`, tearing the session down kills
  the watchdog before it can count down, and if the change is the reason you
  cannot reconnect there is nothing left watching. Check with
  `grep -i KillUserProcesses /etc/systemd/logind.conf`: a commented line means
  the build default applies, and the distributions differ on what that is.
  Escaping the scope means starting the watchdog outside the login session,
  which is a unit or a root-side helper rather than a line of this script, so
  it is not implemented here and the exposure above is unverified against a
  real session teardown. Until it is settled, `deadman-ssh status` from a
  second machine is part of the procedure, not a convenience.
- **A change that breaks something a hook does not cover.** The switch restores
  what the hooks captured. A wrong route with no route hook rolls back nothing.
- **A machine that stays up but is wedged.** Liveness of the SSH socket is not
  health. A host that is reachable and broken is confirmed by you, not by the
  switch.
- **A rollback that half-succeeds.** The exit status and the state file say
  `rollback-failed` and name the hooks that broke, but the host is in whatever
  state the failure left it. There is no transactional restore, and
  `recover` retrying it is tested only against fixture hooks.
- **Loss of the state directory.** Snapshots live under the user's state
  directory. A change that wipes the filesystem removes the thing it would
  have rolled back to.
- **`confirm` typed too early.** The switch takes your word for it and stands
  down. There is no second check that the box is really reachable.

## License

[MIT](LICENSE). © 2026 Shayan Golmezerji.
