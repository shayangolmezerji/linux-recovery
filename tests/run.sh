#!/usr/bin/env bash
# Test harness for deadman-ssh. Plain bash plus coreutils on purpose: the
# target box has no bats, no pytest and no root, and a switch that cannot be
# tested there is not testable.
#
# Everything runs with DEADMAN_DRY_RUN=1 against a scratch state directory under
# $TMPDIR, so the suite observes the arm -> expire -> rollback sequence without
# touching a single system file. The two tests that turn dry-run off use fixture
# hooks that only write inside the scratch directory, plus a payload of `false`.
# Nothing here calls nft, ip, iptables, tc or systemctl, and the only processes
# ever signalled are watchdogs this harness started itself.
#
# bats is not a dependency, so the runner is hand-rolled: a test is a function
# named test_*, and every check is one of the expect_* calls below.
set -euo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
DM="$ROOT/bin/deadman-ssh"
FIXTURE_HOOKS="$TESTS_DIR/fixtures/hooks.d"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/deadman-tests.XXXXXX")
STATE=$WORK/state
TRACE=$WORK/trace
BOOTID=$WORK/boot_id

pass=0
fail=0
current='(none)'

cleanup() {
  [[ -n ${WORK:-} && -d ${WORK:-} ]] || return 0
  local file pid
  while IFS= read -r file; do
    pid=$(<"$file")
    # A pid file is only ever a hint: the number may already belong to another
    # process by now, so signal nothing this harness cannot name.
    if [[ -n $pid && -r /proc/$pid/cmdline ]] &&
      tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q 'deadman-ssh watch'; then
      kill "$pid" 2>/dev/null || true
    fi
  done < <(find "$WORK" -name watchpid 2>/dev/null)
  rm -rf "$WORK"
}
trap cleanup EXIT

# SSH_CONNECTION would switch the probe from the timer to a live socket table,
# which makes these tests depend on how the runner happens to be logged in. The
# probe tests set it per call.
unset SSH_CONNECTION
export DEADMAN_DRY_RUN=1
export DEADMAN_STATE_DIR="$STATE"
export DEADMAN_HOOKS_DIR="$FIXTURE_HOOKS"
export DM_TEST_TRACE="$TRACE"
export DEADMAN_BOOT_ID_FILE="$BOOTID"
printf 'boot-under-test\n' >"$BOOTID"

note() { printf '%s\n' "$*"; }

section() {
  current=$1
  printf '\n== %s\n' "$1"
}

ok() {
  pass=$((pass + 1))
  printf '  ok   %s\n' "$*"
}

bad() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$*"
  printf '       in test: %s\n' "$current"
}

# Runs the CLI with combined output. Result in OUT, status in RC.
OUT=''
RC=0
run() {
  RC=0
  OUT=$("$DM" "$@" 2>&1) || RC=$?
}

# One variable overridden for a single call, used to point the hook directory at
# the shipped hooks.d and to fake a session pid.
run_with_env() {
  local assignment=$1
  shift
  RC=0
  OUT=$(env "$assignment" "$DM" "$@" 2>&1) || RC=$?
}

# The fixture hooks never need privilege, so the two cases that only say
# something about a real run (a change that fails, a change that must not be
# reached) turn dry-run off and still touch nothing but the scratch directory.
run_real() {
  RC=0
  OUT=$(env -u DEADMAN_DRY_RUN "$DM" "$@" 2>&1) || RC=$?
}

expect_rc() {
  local want=$1 name=$2
  if [[ $RC == "$want" ]]; then
    ok "$name (rc=$RC)"
  else
    bad "$name: expected rc $want, got $RC"
    printf '%s\n' "$OUT" | sed 's/^/       | /'
  fi
}

expect_out() {
  local needle=$1 name=$2
  if [[ $OUT == *"$needle"* ]]; then
    ok "$name"
  else
    bad "$name: output did not contain: $needle"
    printf '%s\n' "$OUT" | sed 's/^/       | /'
  fi
}

expect_absent() {
  local needle=$1 name=$2
  if [[ $OUT != *"$needle"* ]]; then
    ok "$name"
  else
    bad "$name: output should not contain: $needle"
  fi
}

expect_file() {
  local file=$1 name=$2
  if [[ -s $file ]]; then
    ok "$name"
  else
    bad "$name: missing or empty $file"
  fi
}

expect_no_file() {
  local file=$1 name=$2
  if [[ ! -e $file ]]; then
    ok "$name"
  else
    bad "$name: $file should not exist"
  fi
}

expect_trace() {
  local needle=$1 name=$2
  if [[ -f $TRACE ]] && grep -qF -- "$needle" "$TRACE"; then
    ok "$name"
  else
    bad "$name: trace log does not contain '$needle'"
    if [[ -f $TRACE ]]; then
      sed 's/^/       | /' "$TRACE"
    fi
  fi
}

expect_no_trace() {
  local needle=$1 name=$2
  if [[ ! -f $TRACE ]] || ! grep -qF -- "$needle" "$TRACE"; then
    ok "$name"
  else
    bad "$name: trace log should not contain '$needle'"
    sed 's/^/       | /' "$TRACE"
  fi
}

# Line number of the first match in the trace, for ordering assertions.
trace_line() {
  grep -nF -- "$1" "$TRACE" | head -n1 | cut -d: -f1
}

# Same as expect_trace, for the per-session watchdog log written by deadman-ssh.
expect_log() {
  local id=$1 needle=$2 name=$3
  if grep -qF -- "$needle" "$(hook_log "$id")" 2>/dev/null; then
    ok "$name"
  else
    bad "$name: $(hook_log "$id") does not contain '$needle'"
    dump_log "$id"
  fi
}

dump_log() {
  sed 's/^/       | /' "$(hook_log "$1")" 2>/dev/null || true
}

# Waits for a condition to become true. Bounded, so a broken watchdog fails the
# test instead of hanging the suite.
waits_for() {
  local limit=$1
  shift
  local tick=0
  while ((tick < limit * 5)); do
    if "$@"; then
      return 0
    fi
    sleep 0.2
    tick=$((tick + 1))
  done
  return 1
}

has_marker() { [[ -e $1 ]]; }

session_state_is() {
  local id=$1 want=$2 got
  got=$(state_get "$id" state 2>/dev/null) || got=''
  [[ $got == "$want" ]]
}

# Reads a key from a session's state file straight from disk, so a broken
# status command cannot mask a real failure.
state_get() {
  local id=$1 key=$2 line file
  file="$STATE/sessions/$id/state"
  [[ -f $file ]] || return 1
  line=$(grep -m1 "^$key=" "$file" 2>/dev/null) || return 1
  printf '%s\n' "${line#*=}"
}

session_dir() { printf '%s\n' "$STATE/sessions/$1"; }
hook_log() { printf '%s\n' "$(session_dir "$1")/log"; }

watchpid_of() { cat "$(session_dir "$1")/watchpid" 2>/dev/null || printf '\n'; }

# Stops the harness's own watchdog so that recover sees a session with nothing
# watching it. Refuses anything that is not this tool, in case a pid was reused.
kill_watchdog() {
  local id=$1 pid
  pid=$(watchpid_of "$id")
  if [[ -n $pid && -r /proc/$pid/cmdline ]] &&
    tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q 'deadman-ssh watch'; then
    kill "$pid" 2>/dev/null || true
    ok "watchdog of $id stopped"
    return 0
  fi
  bad "could not stop the watchdog of $id"
  return 1
}

# A pid the kernel is not using, so the probe reads the session as gone without
# this test signalling anything that might belong to another process.
dead_pid() {
  local max pid
  max=$(cat /proc/sys/kernel/pid_max)
  for pid in $(seq "$((max - 1))" -1 "$((max - 40))"); do
    if [[ ! -d /proc/$pid ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

# --- tests -------------------------------------------------------------

test_usage_errors() {
  section 'bad options are refused before anything is armed'
  run --id bad --ttl '5x' arm
  expect_rc 2 'a ttl that is not a number exits 2'
  expect_out 'must be plain seconds or s/m/h/d' 'and says what a ttl looks like'
  run --id bad --ttl 0 arm
  expect_rc 2 'a zero ttl exits 2'
  run --id bad --ttl arm
  expect_rc 2 'a ttl that ate the command word exits 2, not 0'
  run --id bad --interval 0 --hook 50-alpha arm
  expect_rc 2 'a zero interval exits 2'
  run --id bad --grace -5 arm
  expect_rc 2 'a negative grace exits 2'
  run --id bad --opt valuewithoutkey arm
  expect_rc 2 '--opt without = exits 2'
  run --id bad --hook nosuchhook arm
  expect_rc 2 'an unknown hook name exits 2'
  run --id 'with space' --ttl 300 --hook 50-alpha arm
  expect_rc 2 'an id that is not a single safe path element exits 2'
  expect_no_file "$STATE/sessions/with space" 'the refused id created no directory'
  run --id bad --ttl 300 --hook 50-alpha nosuchcommand
  expect_rc 2 'an unknown command exits 2'
  run --id bad arm ls
  expect_rc 2 'a payload without -- is refused'
  expect_out "arm wants '-- ls'" 'and the message shows the fix'
  run status --id nothing-here
  expect_rc 2 'status for an unknown id exits 2'
  run recover --id nothing-here
  expect_rc 2 'recover for an unknown id exits 2'
  run --id bad --ttl 300 --hook 50-alpha confirm
  expect_rc 2 'confirm with no session at all is a usage error'
}

test_help_and_hooks() {
  section 'help and hook listing'
  run --help
  expect_rc 0 '--help exits 0'
  expect_out 'deadman-ssh arm' 'and prints the usage'
  expect_out 'Exit codes:' 'and documents the exit codes'
  run help
  expect_rc 0 'the help command exits 0'
  run
  expect_rc 0 'no arguments at all prints help instead of failing'
  run version
  expect_rc 0 'version exits 0'
  expect_out 'deadman-ssh 1.0.0' 'and names a version'
  run hooks
  expect_rc 0 'hooks exits 0'
  expect_out '50-alpha' 'the fixture hooks are listed'
  expect_out 'hook directory:' 'and says which directory was read'
}

test_arm_captures_snapshots() {
  section 'arm captures a snapshot for every hook'
  run --id cap --ttl 60 --hook 50-alpha --hook 60-beta arm
  expect_rc 0 'arm exits 0'
  expect_out 'hook 50-alpha: save ok' 'alpha reported a capture'
  expect_out 'hook 60-beta: save ok' 'beta reported a capture'
  expect_file "$(session_dir cap)/snapshots/50-alpha/note" 'alpha snapshot written'
  expect_file "$(session_dir cap)/snapshots/60-beta/note" 'beta snapshot written'
  expect_file "$(session_dir cap)/watchpid" 'watchdog pid recorded'
  expect_absent 'payload' 'no payload means no change claimed'
  expect_out 'only the TTL can fire this rollback' 'the missing probe is logged'
  run --id cap status
  expect_rc 0 'status by --id exits 0'
  expect_out 'state=armed' 'status says armed'
  expect_out 'saved=[50-alpha 60-beta]' 'status lists what can be restored'
  expect_out 'dry_run=1' 'status reports the session ran in dry-run'
  run --id cap disarm
  expect_rc 0 'cleanup disarm'
}

test_expiry_rolls_back_newest_first() {
  section 'an unconfirmed switch expires and rolls back newest hook first'
  : >"$TRACE"
  run --id expire --ttl 1 --interval 1 --hook 50-alpha --hook 60-beta arm
  expect_rc 0 'arm exits 0'
  if ! waits_for 15 has_marker "$(session_dir expire)/ROLLED_BACK"; then
    bad 'rollback never happened'
    dump_log expire
    return 0
  fi
  ok 'rollback marker appeared on its own'
  expect_log expire 'rollback[expired]: complete' 'the watchdog logged the rollback'
  expect_trace 'restore 50-alpha' 'alpha restored'
  expect_trace 'restore 60-beta' 'beta restored'
  local beta_line alpha_line
  beta_line=$(trace_line 'restore 60-beta')
  alpha_line=$(trace_line 'restore 50-alpha')
  if ((beta_line < alpha_line)); then
    ok 'beta restored before alpha (reverse order)'
  else
    bad "restore order is wrong: beta at line $beta_line, alpha at line $alpha_line"
  fi
  session_state_is expire rolled-back && ok 'state is rolled-back' || bad 'state is not rolled-back'
  [[ -n $(state_get expire rolled_back_at) ]] &&
    ok 'the state file records when it fired' || bad 'rolled_back_at is missing'
  expect_reason expire expired 'the marker names the reason'
  run --id expire status
  expect_out 'rolled back:' 'status shows the rollback'
}

# The reason lives in the ROLLED_BACK marker, so grep it rather than the CLI
# output: the expiry happens in the detached watchdog, not in this shell.
expect_reason() {
  local id=$1 want=$2 name=$3
  if grep -qF "reason=$want" "$(session_dir "$id")/ROLLED_BACK" 2>/dev/null; then
    ok "$name"
  else
    bad "$name: ROLLED_BACK does not record reason=$want"
  fi
}

test_confirm_stops_the_switch() {
  section 'confirm stops the watchdog without restoring anything'
  : >"$TRACE"
  run --id confirm --ttl 300 --hook 50-alpha arm
  expect_rc 0 'arm exits 0'
  run --id confirm confirm
  expect_rc 0 'confirm exits 0'
  if ! waits_for 10 session_state_is confirm confirmed; then
    bad 'watchdog did not stand down after confirm'
    dump_log confirm
  else
    ok 'watchdog stood down'
  fi
  expect_no_file "$(session_dir confirm)/ROLLED_BACK" 'no rollback recorded'
  expect_no_trace 'restore' 'no hook ran a restore'
  expect_log confirm 'confirmed (' 'the watchdog logged who confirmed'
  run --id confirm confirm
  expect_rc 3 'a second confirm is refused, the session is confirmed'
  run --id confirm extend
  expect_rc 3 'extend on a confirmed session is refused'
}

test_double_arm_is_refused() {
  section 'arming twice on one id is refused, not silently replaced'
  run --id twin --ttl 300 --hook 50-alpha arm
  expect_rc 0 'first arm exits 0'
  run --id twin --ttl 300 --hook 50-alpha arm
  expect_rc 3 'second arm exits 3'
  expect_out 'is already armed' 'second arm says why'
  expect_out 'confirm it, or arm under a different' 'second arm says what to do'
  local armed_before armed_after
  armed_before=$(state_get twin armed_at)
  run --id twin disarm
  expect_rc 0 'disarm exits 0'
  run --id twin --ttl 300 --hook 50-alpha arm
  expect_rc 3 're-arming a finished session is still refused'
  expect_out 'exists in state disarmed' 'the refusal names the old state'
  run --id twin --force --ttl 300 --hook 50-alpha arm
  expect_rc 0 '--force takes over a finished session'
  expect_out '--force, replacing finished session' 'the takeover is logged'
  armed_after=$(state_get twin armed_at)
  [[ $armed_after != "$armed_before" ]] &&
    ok 'the replaced session has a new armed_at' ||
    bad 'the second arm did not rewrite the session'
  run --id twin disarm --purge
  expect_rc 0 'disarm --purge exits 0'
  expect_no_file "$(session_dir twin)" 'purge deleted the session directory'
}

test_skipped_hook_is_not_restored() {
  section 'a hook that exits 77 is skipped and never restored'
  : >"$TRACE"
  run --id skipper --ttl 1 --interval 1 --hook 50-alpha --hook 77-notapplicable arm
  expect_rc 0 'arm exits 0'
  expect_out 'hook 77-notapplicable: save skipped' 'the skip is reported'
  expect_out 'probe=none' 'the degraded probe is reported'
  if ! waits_for 15 has_marker "$(session_dir skipper)/ROLLED_BACK"; then
    bad 'no rollback'
    dump_log skipper
    return 0
  fi
  ok 'the switch fired on its own'
  expect_no_trace 'restore 77-notapplicable' 'the skipped hook was left alone'
  expect_trace 'restore 50-alpha' 'the hook that did capture was restored'
  run --id skipper status
  expect_out 'saved=[50-alpha]' 'hooks_saved lists only captured hooks'
}

test_failed_snapshot_aborts_before_the_change() {
  section 'a snapshot failure aborts the arm before any change is attempted'
  : >"$TRACE"
  run --id badsnap --ttl 300 --hook 50-alpha --hook 90-failsave arm -- touch "$WORK/should-not-exist"
  expect_rc 1 'arm exits 1'
  expect_out 'aborting before any change is made' 'the abort is explained'
  expect_no_file "$WORK/should-not-exist" 'the payload never ran'
  expect_trace 'restore 50-alpha' 'the hook that did capture was restored'
  expect_no_trace 'restore 90-failsave' 'the failing hook is not restored'
  expect_no_file "$(session_dir badsnap)/snapshots/90-failsave/note" 'the failing hook produced no snapshot'
  expect_reason badsnap snapshot-failed 'the marker names the reason'
}

test_interrupted_capture_rolls_back() {
  section 'an interrupt while capturing aborts the arm and restores what was saved'
  : >"$TRACE"
  RC=0
  OUT=$({
    "$DM" --id interrupt --ttl 300 --hook 50-alpha --hook 80-slowsave arm -- touch "$WORK/also-not" &
    arm_pid=$!
    sleep 0.5
    kill -INT "$arm_pid" 2>/dev/null || true
    wait "$arm_pid"
  } 2>&1) || RC=$?
  expect_rc 1 'the interrupted arm exits 1'
  expect_out 'interrupted while capturing' 'the abort is logged'
  expect_no_file "$WORK/also-not" 'the payload never ran'
  expect_trace 'restore 50-alpha' 'the captured hook was restored'
  session_state_is interrupt rolled-back &&
    ok 'state is rolled-back' || bad 'an interrupted arm left the session open'
  expect_file "$(session_dir interrupt)/log" 'the aborted arm left a log'
}

test_grace_cuts_the_deadline_short() {
  section 'a dead session probe brings the deadline forward'
  : >"$TRACE"
  local dead
  dead=$(dead_pid)
  run_with_env "DM_SESSION_PID=$dead" --id grace --ttl 600 --interval 1 --grace 0 --hook 50-alpha arm
  expect_rc 0 'arm exits 0'
  expect_out 'probe=pid '"$dead" 'the pid probe was picked'
  if ! waits_for 15 has_marker "$(session_dir grace)/ROLLED_BACK"; then
    bad 'the switch waited for a 600s deadline on a dead session'
    dump_log grace
    return 0
  fi
  ok 'the rollback fired long before the ttl'
  expect_log grace 'session is gone' 'the watchdog saw the session drop'
  session_state_is grace rolled-back && ok 'state is rolled-back' || bad 'state is not rolled-back'
}

test_probe_degrades_to_the_timer() {
  section 'an SSH_CONNECTION with no matching socket degrades to the timer'
  # 192.0.2.0/24 is documentation space: never a real peer of this host.
  run_with_env 'SSH_CONNECTION=192.0.2.1 45455 192.0.2.2 22' \
    --id degrade --ttl 30 --hook 50-alpha arm
  expect_rc 0 'arm exits 0'
  expect_out 'probe: SSH_CONNECTION is set' 'the unusable probe is explained'
  expect_absent 'probe=socket' 'an unverifiable socket tuple is not trusted'
  run --id degrade status
  expect_out 'probe=none' 'the session falls back to the timer'
  expect_rc 0 'and status still answers'
  # The other direction is the dangerous one: an unusable probe must not be
  # read as "the operator left", which would roll back a live session.
  if waits_for 3 has_marker "$(session_dir degrade)/ROLLED_BACK"; then
    bad 'a dropped probe fired the rollback early'
    dump_log degrade
  else
    ok 'a dropped probe did not fire the rollback'
  fi
  session_state_is degrade armed && ok 'the session is still armed' || bad 'state is not armed'
  run --id degrade disarm
  expect_rc 0 'cleanup disarm'
}

test_extend_moves_the_deadline() {
  section 'extend moves the deadline of an armed session'
  run --id longer --ttl 60 --hook 50-alpha arm
  expect_rc 0 'arm exits 0'
  local before after
  before=$(state_get longer deadline)
  run --id longer extend --ttl 2h
  expect_rc 0 'extend accepts an h suffix'
  after=$(state_get longer deadline)
  ((after >= before + 7100)) &&
    ok "the deadline moved by about two hours ($before to $after)" ||
    bad "extend did not move the deadline far enough ($before to $after)"
  run --id longer status
  expect_out 'left=7' 'status counts down in minutes'
  run --id longer disarm
  expect_rc 0 'cleanup disarm'
}

test_dry_run_prints_privileged_commands() {
  section 'dry-run prints the exact command instead of running it'
  # The shipped hook, not a fixture, and the only test that reads hooks.d: the
  # plan it prints is what an operator would review before arming for real.
  run_with_env "DEADMAN_HOOKS_DIR=$ROOT/hooks.d" --id nft --ttl 300 arm
  expect_rc 0 'the shipped nftables hook captures'
  expect_out 'DRY-RUN capture ruleset.nft <= nft list ruleset' 'the capture is printed'
  expect_out 'DRY-RUN' 'and nothing was executed'
  run --id nft rollback --reason reviewed
  expect_rc 4 'forced rollback reports that it fired'
  expect_out 'DRY-RUN nft flush ruleset' 'the flush is printed'
  expect_out 'DRY-RUN nft -f' 'the reload is printed'
  expect_reason nft reviewed 'the manual rollback records its reason'
  expect_no_trace 'flush' 'the plan never reached the trace log'
}

test_recover_rolls_back_after_a_reboot() {
  section 'recover rolls back a session left armed across a reboot'
  : >"$TRACE"
  run --id rebooted --ttl 600 --hook 50-alpha arm
  expect_rc 0 'arm exits 0'
  kill_watchdog rebooted || return 0
  # A host coming back is what changes the boot id. Nothing here is armed over.
  printf 'boot-after-reboot\n' >"$BOOTID"
  run --id rebooted recover
  expect_rc 0 'recover exits 0'
  expect_out 'was armed in boot boot-under-test and this host booted as boot-after-reboot' \
    'the reboot is named'
  expect_trace 'restore 50-alpha' 'the hook restored'
  session_state_is rebooted rolled-back && ok 'state is rolled-back' || bad 'state is not rolled-back'
  printf 'boot-under-test\n' >"$BOOTID"
}

test_recover_restarts_a_watchdog() {
  section 'recover restarts the watchdog of a session with time left'
  : >"$TRACE"
  run --id watched --ttl 600 --hook 50-alpha arm
  expect_rc 0 'arm exits 0'
  local first_pid
  first_pid=$(watchpid_of watched)
  kill_watchdog watched || return 0
  run --id watched recover
  expect_rc 0 'recover exits 0'
  expect_out 'has 9m and no watchdog, starting a new one' 'the restart is logged'
  local second_pid
  second_pid=$(watchpid_of watched)
  [[ $second_pid != "$first_pid" ]] &&
    ok "a new watchdog is running ($first_pid to $second_pid)" ||
    bad 'recover did not replace the watchdog'
  run --id watched disarm
  expect_rc 0 'cleanup disarm'
  run --id watched recover
  expect_rc 0 'recover of a disarmed session is a no-op'
  expect_out 'recover: nothing pending' 'and says so'
}

test_positional_id_is_accepted() {
  section 'the session operand after the command works like --id'
  run --id pos --ttl 300 --hook 50-alpha arm
  expect_rc 0 'arm exits 0'
  run status pos
  expect_rc 0 'status by operand exits 0'
  expect_out 'id=pos' 'the operand picked the right session'
  run extend pos --ttl 900
  expect_rc 0 'extend by operand exits 0'
  run confirm pos
  expect_rc 0 'confirm by operand exits 0'
  run status pos pos2
  expect_rc 2 'two operands are refused'
  run --id pos disarm --purge
  expect_rc 0 'cleanup disarm --purge'
}

test_payload_failure_rolls_back_at_once() {
  section 'a change that fails on its own rolls back immediately'
  # Dry-run is off here: these hooks are shell scripts that only write to the
  # scratch directory, so this is the one case that exercises a real run.
  : >"$TRACE"
  run_real --id payload --ttl 300 --hook 50-alpha arm -- false
  expect_rc 1 'arm exits 1 when the change fails'
  expect_out 'the change itself exited' 'the failure is named'
  expect_trace 'restore 50-alpha' 'the rollback ran without waiting for the TTL'
  expect_no_trace 'restore 60-beta' 'only captured hooks are restored'
  session_state_is payload rolled-back && ok 'state is rolled-back' || bad 'state is not rolled-back'
  expect_reason payload payload-failed 'the marker names the reason'
}

test_shellcheck_if_present() {
  section 'shellcheck on every script'
  if ! command -v shellcheck >/dev/null 2>&1; then
    note '  SKIP shellcheck is not installed on this machine'
    note '       install it, or run the CI workflow, to get this check'
    return 0
  fi
  local file
  for file in "$DM" "$ROOT/lib/deadman-lib.sh" "$ROOT"/hooks.d/* "$TESTS_DIR"/fixtures/hooks.d/* "$TESTS_DIR/run.sh"; do
    if shellcheck --severity=warning "$file"; then
      ok "shellcheck: $(basename "$file")"
    else
      bad "shellcheck: $(basename "$file")"
    fi
  done
}

# --- run ---------------------------------------------------------------

note "deadman-ssh test harness"
note "scratch state: $WORK"

test_usage_errors
test_help_and_hooks
test_shellcheck_if_present
test_arm_captures_snapshots
test_dry_run_prints_privileged_commands
test_positional_id_is_accepted
test_confirm_stops_the_switch
test_double_arm_is_refused
test_failed_snapshot_aborts_before_the_change
test_interrupted_capture_rolls_back
test_skipped_hook_is_not_restored
test_grace_cuts_the_deadline_short
test_probe_degrades_to_the_timer
test_extend_moves_the_deadline
test_expiry_rolls_back_newest_first
test_recover_rolls_back_after_a_reboot
test_recover_restarts_a_watchdog
test_payload_failure_rolls_back_at_once

if ((fail > 0)); then
  printf '\n%d checks passed, %d FAILED\n' "$pass" "$fail"
  exit 1
fi
printf '\n%d checks passed, 0 failed\n' "$pass"
