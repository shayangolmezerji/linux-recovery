#!/usr/bin/env bash
# Test harness for deadman-ssh. Plain bash plus coreutils on purpose: the
# target box has no bats, no pytest and no root, and a switch that cannot be
# tested there is not testable.
#
# Everything runs with DEADMAN_DRY_RUN=1 against a scratch state directory under
# $TMPDIR, so the suite observes the arm -> expire -> rollback sequence without
# touching a single system file. Three tests turn dry-run off, because dry-run is
# what would hide the answer there: a payload that fails, a snapshot that fails,
# a capture that is interrupted. They use fixture hooks that only write inside
# the scratch directory, and payloads of `false` or `touch`. Nothing here calls
# nft, ip, iptables, tc or systemctl, and DEADMAN_RUNNER is pinned to `false` so
# that a stray privileged call fails instead of escalating. The socket probe
# tests run against a fake `ss` this harness puts on PATH; the one test that asks
# the host's own ss only ever lists it, and passes whichever way that goes. The
# only processes ever signalled are the watchdogs and the single arm that this
# harness started itself, and each pid is checked against /proc first.
#
# bats is not a dependency, so the runner is hand-rolled: a test is a function
# named test_*, and every check is one of the expect_* calls below.
set -euo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$TESTS_DIR/.." && pwd)
DM="$ROOT/bin/deadman-ssh"
FIXTURE_HOOKS="$TESTS_DIR/fixtures/hooks.d"
FIXTURE_BIN="$TESTS_DIR/fixtures/bin"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/deadman-tests.XXXXXX")
STATE=$WORK/state
TRACE=$WORK/trace
BOOTID=$WORK/boot_id
SSTABLE=$WORK/ss-table

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
# The escalator is fake for the whole suite. No test is supposed to reach it, and
# a run that does must fail rather than hand this host a real `sudo -n`.
export DEADMAN_RUNNER='false'
printf 'boot-under-test\n' >"$BOOTID"
# The fake `ss` in fixtures/bin prints whatever is in this file, so the socket
# probe can be shown both iproute2 column layouts, and made to lose the session
# halfway through a run, without a live SSH connection anywhere near it.
export DM_FAKE_SS_TABLE="$SSTABLE"
: >"$SSTABLE"

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

# The session every socket test pretends to be. 192.0.2.0/24 is documentation
# space, so no peer of this host can ever match it, and SS_ROWS holds the two
# column layouts iproute2 has been seen to print for `ss -Htn state established`:
# with and without the leading State column.
SS_TUPLE='192.0.2.1 45455 192.0.2.2 22'
SS_ROWS=(
  '0 0 192.0.2.2:22 192.0.2.1:45455'
  'ESTAB 0 0 192.0.2.2:22 192.0.2.1:45455'
)

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

# Arms with SS_TUPLE, with the fake ss in fixtures/bin ahead of the host's own on
# PATH. The watchdog inherits both, so a probe stays readable after the arm too.
run_with_ss() {
  RC=0
  OUT=$(env "PATH=$FIXTURE_BIN:$PATH" "SSH_CONNECTION=$SS_TUPLE" "$DM" "$@" 2>&1) || RC=$?
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

# For output that is only partly predictable: a countdown depends on how long
# the arm took, so the shape is asserted and the number is not.
expect_out_matching() {
  local regex=$1 name=$2
  if [[ $OUT =~ $regex ]]; then
    ok "$name (matched $regex)"
  else
    bad "$name: output did not match: $regex"
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

# Counts a hook action in the trace. Absence assertions only prove the hook was
# never called if a wrong count is also a failure, so the number is the check.
expect_trace_count() {
  local needle=$1 want=$2 name=$3 got
  got=$(grep -cF -- "$needle" "$TRACE" 2>/dev/null) || got=0
  if [[ $got == "$want" ]]; then
    ok "$name"
  else
    bad "$name: trace has $got lines matching '$needle', want $want"
    [[ -f $TRACE ]] && sed 's/^/       | /' "$TRACE"
  fi
}

# For a snapshot file whose content is the point: a dry-run capture must hold a
# placeholder, not the output of a command that never ran.
expect_file_contains() {
  local file=$1 needle=$2 name=$3
  if [[ -f $file ]] && grep -qF -- "$needle" "$file"; then
    ok "$name"
  else
    bad "$name: $file does not contain '$needle'"
    [[ -f $file ]] && sed 's/^/       | /' "$file"
  fi
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
  # The key is the half of the option that becomes a variable name, so it is
  # asked here rather than by export, which answers an invalid identifier with a
  # shell error and an arm that exits 1.
  run --id optkey --opt 'bad-key=1' arm
  expect_rc 2 'an --opt key that is not a variable name exits 2'
  expect_out "--opt key 'bad-key' must be letters" 'and the refusal names the key'
  expect_no_file "$(session_dir optkey)" 'the refused --opt armed nothing'
  run --id optline --opt $'a\nb=1' arm
  expect_rc 2 'an --opt key spanning a line is refused too'
  expect_no_file "$(session_dir optline)" 'and it never reached the export'
  run --id optgood --ttl 300 --hook 50-alpha --opt NOTE=ok_1 --opt '_Also=1' arm
  expect_rc 0 'a key with a digit, an underscore or both is armed with'
  run --id optgood disarm --purge
  expect_rc 0 'cleanup disarm --purge'
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

# A hook name is the only user-supplied string that reaches an execution this
# tool cannot re-check: arm writes it into hooks_saved, which the watchdog reads
# back with word splitting, and that watchdog then runs the file the name names
# from a process with no arguments left to validate, on the way to a hook that
# escalates. The shape check refuses a name that is not one file name; the
# containment check refuses one that is well formed but resolves outside the hook
# directory, which is what a symlink there does.
test_hook_names_cannot_escape_the_directory() {
  section 'a hostile hook name cannot be stored or run from outside hooks.d'
  # A scratch hook directory with an executable sitting next to it: pointing
  # --hook at the repo's own tree would make the escape test depend on a file
  # the harness has no business running.
  local dir=$WORK/escape-hooks outside=$WORK/escape-outside
  mkdir -p "$dir" "$outside"
  cp "$FIXTURE_HOOKS/50-alpha" "$dir/50-alpha"
  cp "$FIXTURE_HOOKS/60-beta" "$outside/60-beta"
  ln -s "$outside/60-beta" "$dir/30-link"
  : >"$TRACE"

  run_with_env "DEADMAN_HOOKS_DIR=$dir" --id slash --ttl 300 \
    --hook 50-alpha --hook '../escape-outside/60-beta' arm
  expect_rc 2 'a hook name with a slash is refused'
  expect_out 'may only contain letters' 'and the refusal says what a name is'
  expect_no_trace 'save 60-beta' 'nothing outside the hook directory was run'
  expect_no_file "$(session_dir slash)" 'the refused arm stored no session'

  run_with_env "DEADMAN_HOOKS_DIR=$dir" --id comma --ttl 300 \
    --hook '50-alpha,../escape-outside/60-beta' arm
  expect_rc 2 'a comma list is checked piece by piece, not as a whole'
  expect_no_trace 'save 60-beta' 'and the good piece did not buy a pass for the bad one'

  run_with_env "DEADMAN_HOOKS_DIR=$dir" --id dotdot --ttl 300 \
    --hook '..' arm
  expect_rc 2 'the parent directory is not a hook name'

  # --hook is split with read, which stops at a line break. Without a refusal
  # the rest of the value disappears and the arm captures a different list of
  # hooks from the one that was typed.
  run_with_env "DEADMAN_HOOKS_DIR=$dir" --id newline --ttl 300 \
    --hook $'50-alpha\nhooks_saved=' arm
  expect_rc 2 'a hook name spanning a line is refused outright'
  expect_no_file "$(session_dir newline)" 'and nothing was armed behind the refusal'

  # Well formed, executable, and still not this directory's file to run.
  run_with_env "DEADMAN_HOOKS_DIR=$dir" --id symlink --ttl 300 \
    --hook 30-link arm
  expect_rc 2 'a hook that resolves outside the directory is refused'
  expect_out 'is not a plain file inside' 'and the refusal names the directory'
  expect_no_trace 'save 60-beta' 'and the target never ran'

  # The same entry reached through the default listing instead of --hook.
  run_with_env "DEADMAN_HOOKS_DIR=$dir" --id listed --ttl 300 arm
  expect_rc 2 'the default listing is held to the same containment'
  expect_no_trace 'save 60-beta' 'so an escaping entry is not silently captured'

  run --id normal --ttl 300 --hook 50-alpha arm
  expect_rc 0 'a plain arm still works after all of those refusals'
  expect_out 'hook 50-alpha: save ok' 'and the fixture hooks are untouched'
  run --id normal status
  expect_out 'saved=[50-alpha]' 'hooks_saved holds one plain name'
  run --id normal disarm --purge
  expect_rc 0 'cleanup disarm --purge'
}

# The state file is the second boundary. hooks_saved is read back at recover
# time by a process that never saw the arm's arguments, long after the write and
# possibly by a build that is not the one that wrote it. The name it holds
# picks the file that runs as the arming user, so the containment resolve_hooks
# applies to a typed name has to apply to a stored one too.
test_stored_hook_names_are_contained_at_recover() {
  section 'a hook name read back from the state file is contained too'
  local dir=$WORK/restore-hooks outside=$WORK/restore-outside
  mkdir -p "$dir" "$outside"
  cp "$FIXTURE_HOOKS/50-alpha" "$dir/50-alpha"
  cp "$FIXTURE_HOOKS/60-beta" "$outside/60-beta"
  : >"$TRACE"

  run_with_env "DEADMAN_HOOKS_DIR=$dir" --id stored --ttl 600 --hook 50-alpha arm
  expect_rc 0 'the session under test arms'
  kill_watchdog stored || return 0
  # The reboot branch of recover, because that is the read made by a build other
  # than the one that armed the session.
  printf 'boot-after-reboot\n' >"$BOOTID"

  # What a build that predates the name check stored, since --hook took paths
  # then: the traversal sits next to the plain name it also stored.
  local file=$(session_dir stored)/state line tmp
  tmp=$file.tmp
  while IFS= read -r line; do
    [[ $line == hooks_saved=* ]] &&
      line='hooks_saved=50-alpha ../restore-outside/60-beta'
    printf '%s\n' "$line"
  done <"$file" >"$tmp"
  mv "$tmp" "$file"

  run --id stored recover
  expect_rc 0 'recover of the session with a traversal stored exits 0'
  expect_out 'hook ../restore-outside/60-beta is not a plain file inside' \
    'the stored name is refused the way a typed one is'
  expect_no_trace '60-beta' 'and the executable outside the hook directory never ran'
  expect_no_file "$(session_dir stored)/restore-outside" \
    'and the refused name built no snapshot directory either'
  expect_trace 'restore 50-alpha' 'the hook that is contained still restored'
  expect_out '1 hook(s) failed' 'the refusal is reported as a failed hook'
  session_state_is stored rollback-failed &&
    ok 'and the session is not marked restored' ||
    bad 'a refused stored name left the session looking rolled back'
  printf 'boot-under-test\n' >"$BOOTID"
  run --id stored disarm --purge
  expect_rc 0 'cleanup disarm --purge'
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
  # cmd_hooks reads the `# hook-opt` marker out of the hook itself, so an
  # operator sees what a hook accepts without opening it.
  expect_out_matching '50-alpha[[:space:]]+opts: nothing' 'a declared option is listed'
  expect_out_matching '60-beta[[:space:]]+opts: none' 'a hook with none says so'
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

# DEADMAN_OPT_<KEY> is exported only by the arm process. A rollback is a separate
# invocation, and the detached watchdog even more so, so an option earns its
# keep only if the hook captured its effect into the snapshot: the restore half
# of this test runs in a process that never saw --opt at all.
test_options_reach_the_hook() {
  section '--opt is exported to the hook as DEADMAN_OPT_<KEY>'
  run --id opt --ttl 300 --hook 50-alpha --opt NOTE=by-hand arm
  expect_rc 0 'arm with --opt exits 0'
  expect_file_contains "$(session_dir opt)/snapshots/50-alpha/note" \
    'note=by-hand' 'the hook saw the option while capturing'
  run --id opt rollback --reason reviewed
  expect_rc 4 'the rollback reports that it fired'
  expect_out 'alpha restored alpha state' 'the hook ran its restore'
  expect_out 'note=by-hand' 'the value comes back from the snapshot, not the option'
  run --id opt status
  expect_out 'state=rolled-back' 'the session shows the rollback'
  run --id opt disarm --purge
  expect_rc 0 'cleanup disarm --purge'
}

# Two of the three hook invocations happen in a process that never parsed the
# arm's arguments: `rollback` from an operator typing it, and the detached
# `watch` that fires on its own. Both have to hand a hook the library anyway, or
# the rollback a hook exists to perform is the one thing it cannot do. The
# recover path is the fourth: after a reboot the arm is gone and `recover` runs
# the restore itself, in a process that never exported anything.
test_hooks_see_the_library_in_every_process() {
  section 'DEADMAN_LIB reaches a hook in every process that runs one'
  : >"$TRACE"
  run --id libcli --ttl 300 --hook 40-libseen arm
  expect_rc 0 'arm exits 0'
  expect_file_contains "$(session_dir libcli)/snapshots/40-libseen/note" \
    'DEADMAN_LIB=' 'the arm handed the hook a library path'
  run --id libcli rollback --reason reviewed
  expect_rc 4 'a rollback from a second process exits 4'
  expect_out 'hook 40-libseen: restore ok' 'and the hook found the library there'
  run --id libcli disarm --purge
  expect_rc 0 'cleanup disarm --purge'

  run --id libfire --ttl 1 --interval 1 --hook 40-libseen arm
  expect_rc 0 'arm of the self-firing session exits 0'
  if ! waits_for 15 has_marker "$(session_dir libfire)/ROLLED_BACK"; then
    bad 'the watchdog never fired'
    dump_log libfire
    return 0
  fi
  ok 'the watchdog fired on its own'
  expect_log libfire 'hook 40-libseen: restore ok' 'the detached watchdog saw it too'
  session_state_is libfire rolled-back &&
    ok 'state is rolled-back' || bad 'a rollback in the watchdog left the session open'
  run --id libfire disarm --purge
  expect_rc 0 'cleanup disarm --purge'

  # The reboot branch of recover: the restore runs in the recover process, which
  # never saw the arm's environment, so this is the row the arm-time export
  # never covered.
  run --id libreboot --ttl 600 --hook 40-libseen arm
  expect_rc 0 'arm of the recover session exits 0'
  kill_watchdog libreboot || return 0
  printf 'boot-after-reboot\n' >"$BOOTID"
  run --id libreboot recover
  expect_rc 0 'recover exits 0'
  expect_out 'hook 40-libseen: restore ok' 'recover handed the hook the library too'
  session_state_is libreboot rolled-back &&
    ok 'the recovered session is rolled-back' || bad 'recover did not finish the restore'
  printf 'boot-under-test\n' >"$BOOTID"
  run --id libreboot disarm --purge
  expect_rc 0 'cleanup disarm --purge'
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
  # armed_at has one-second resolution and the arms run faster than that, so
  # without the pause a rewrite could land in the same second and read as a
  # session that was never replaced.
  sleep 1
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
  # Dry-run off: with it on, the payload is never executed whichever way this
  # test goes, and "the payload never ran" would assert nothing.
  run_real --id badsnap --ttl 300 --hook 50-alpha --hook 90-failsave arm -- touch "$WORK/should-not-exist"
  expect_rc 1 'arm exits 1'
  expect_out 'aborting before any change is made' 'the abort is explained'
  expect_no_file "$WORK/should-not-exist" 'the payload never ran'
  expect_trace 'restore 50-alpha' 'the hook that did capture was restored'
  expect_no_trace 'restore 90-failsave' 'the failing hook is not restored'
  expect_no_file "$(session_dir badsnap)/snapshots/90-failsave/note" 'the failing hook produced no snapshot'
  expect_reason badsnap snapshot-failed 'the marker names the reason'
}

test_interrupted_capture_rolls_back() {
  section 'a signal while capturing aborts the arm and restores what was saved'
  : >"$TRACE"
  local arm_out=$WORK/interrupt.out arm_pid
  RC=0
  # Two things have to go right for this to test anything. Dry-run is off, or the
  # payload would never run and its absence would prove nothing. And job control
  # is on: a background command of a non-interactive shell inherits SIGINT as
  # ignored, bash refuses to trap a signal it was entered with ignored, and the
  # kill below would be swallowed by the arm instead of reaching its trap.
  set -m
  {
    env -u DEADMAN_DRY_RUN "$DM" --id interrupt --ttl 300 \
      --hook 50-alpha --hook 80-slowsave arm -- touch "$WORK/also-not" >"$arm_out" 2>&1 &
    arm_pid=$!
    sleep 0.5
    kill -INT "$arm_pid" 2>/dev/null || true
    wait "$arm_pid" || RC=$?
  }
  set +m
  OUT=$(<"$arm_out")
  expect_rc 1 'the interrupted arm exits 1'
  expect_out 'interrupted while capturing' 'the abort is logged'
  expect_no_file "$WORK/also-not" 'the payload never ran'
  expect_trace 'restore 50-alpha' 'the captured hook was restored'
  expect_trace_count 'restore ' 1 'nothing but the captured hook was restored'
  session_state_is interrupt rolled-back &&
    ok 'state is rolled-back' || bad 'an interrupted arm left the session open'
  # The abort is recorded in the marker, not in a watchdog log: the watchdog
  # never started, so there is no log file for an arm that died capturing. The
  # marker names the phase that failed, the state file names what caused it.
  expect_reason interrupt snapshot-failed 'the marker records the capture as failed'
  [[ $(state_get interrupt failed_hook) == interrupted ]] &&
    ok 'the state file records the cause as an interrupt' ||
    bad "failed_hook is '$(state_get interrupt failed_hook)', not interrupted"
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

test_socket_probe_reads_either_layout() {
  section 'the socket probe reads the endpoint pair, not a fixed column'
  local n=0 row id
  for row in "${SS_ROWS[@]}"; do
    n=$((n + 1))
    id="socklayout$n"
    printf '%s\n' "$row" >"$SSTABLE"
    run_with_ss --id "$id" --ttl 60 --hook 50-alpha arm
    expect_rc 0 "arm against this table exits 0 ($row)"
    expect_out 'probe=socket 192.0.2.2:22 192.0.2.1:45455' \
      'the tuple is recorded local first, then peer'
    run --id "$id" status
    expect_out 'probe=socket' "status of layout $n reports a socket probe"
    run --id "$id" disarm
    expect_rc 0 "cleanup disarm of layout $n"
  done
}

test_socket_loss_cuts_the_deadline() {
  section 'a socket that disappears brings the deadline forward'
  : >"$TRACE"
  printf '%s\n' "${SS_ROWS[0]}" >"$SSTABLE"
  run_with_ss --id sockdrop --ttl 600 --interval 1 --grace 0 --hook 50-alpha arm
  expect_rc 0 'arm exits 0'
  expect_out 'probe=socket' 'the socket probe was picked'
  # The operator's connection drops mid-change: the table goes empty under a
  # running watchdog, which has to roll back now rather than wait out the 600s
  # deadline it was armed with.
  : >"$SSTABLE"
  if ! waits_for 15 has_marker "$(session_dir sockdrop)/ROLLED_BACK"; then
    bad 'the switch waited for a 600s deadline on a dropped socket'
    dump_log sockdrop
    return 0
  fi
  ok 'the rollback fired on the dropped socket'
  expect_log sockdrop 'session is gone' 'the watchdog saw the socket drop'
  expect_trace 'restore 50-alpha' 'the captured hook was restored'
  session_state_is sockdrop rolled-back && ok 'state is rolled-back' || bad 'state is not rolled-back'
  expect_reason sockdrop expired 'the marker names the reason'
}

test_unreadable_socket_is_not_a_gone_session() {
  section 'a socket table that cannot be read does not fire the rollback'
  printf '%s\n' "${SS_ROWS[0]}" >"$SSTABLE"
  run_with_ss --id sockblind --ttl 60 --interval 1 --grace 0 --hook 50-alpha arm
  expect_rc 0 'arm exits 0'
  expect_out 'probe=socket' 'the socket probe was picked'
  # Deleting the file makes the fake ss exit non-zero, which is what an ss that is
  # missing or refusing to answer looks like. This is the dangerous direction: a
  # watchdog that read "cannot tell" as "the operator left" would roll back a live
  # session within a second, which is what --grace 0 makes observable.
  rm -f "$SSTABLE"
  if waits_for 6 has_marker "$(session_dir sockblind)/ROLLED_BACK"; then
    bad 'an unreadable socket table was read as a dropped session'
    dump_log sockblind
  else
    ok 'an unreadable socket table did not fire the rollback'
  fi
  session_state_is sockblind armed && ok 'the session is still armed' || bad 'state is not armed'
  run --id sockblind disarm
  expect_rc 0 'cleanup disarm'
  printf '%s\n' "${SS_ROWS[0]}" >"$SSTABLE"
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

test_ipv6_tuple_falls_back_to_the_timer() {
  section 'an IPv6 peer is refused as a socket probe, not read as a dead session'
  # An IPv6 address already contains colons, so the endpoint string built from it
  # is ambiguous and does not reliably match what ss prints. pick_probe therefore
  # accepts dotted-quad only. The dangerous part is not the refusal, it is what a
  # refusal must not be allowed to look like: with --grace 0, reading the session
  # as gone would roll back a live IPv6 operator's box in seconds.
  #
  # run_with_ss reads the shared tuple, so the override below is scoped to this
  # test: left set, every later socket case would arm with an IPv6 peer and
  # silently exercise the fallback instead of the probe.
  local n=0 tuple id saved_tuple=$SS_TUPLE
  for tuple in '[2001:db8::1] 45455 192.0.2.2 22' '2001:db8::1 45455 192.0.2.2 22'; do
    n=$((n + 1))
    id="ipv6-$n"
    SS_TUPLE=$tuple
    printf '[2001:db8::1]:45455 192.0.2.2:22\n' >"$SSTABLE"
    run_with_ss --id "$id" --ttl 60 --interval 1 --grace 0 --hook 50-alpha arm
    expect_rc 0 "arm with '$tuple' exits 0"
    expect_absent 'probe=socket' "the IPv6 tuple is not picked as a probe ($n)"
    run --id "$id" status
    expect_out 'probe=none' "session $n runs on the timer"
  done
  # The table and the tuples stay as they are: a watchdog that cannot read the
  # session must wait for the ttl like any other, so nothing fires here.
  if waits_for 4 has_marker "$(session_dir ipv6-1)/ROLLED_BACK" ||
    has_marker "$(session_dir ipv6-2)/ROLLED_BACK"; then
    bad 'a refused IPv6 tuple was read as a dropped session'
    dump_log ipv6-1
    dump_log ipv6-2
  else
    ok 'a refused IPv6 tuple did not fire the rollback'
  fi
  session_state_is ipv6-1 armed && ok 'the first session is still armed' || bad 'ipv6-1 is not armed'
  session_state_is ipv6-2 armed && ok 'the second session is still armed' || bad 'ipv6-2 is not armed'
  run --id ipv6-1 disarm
  expect_rc 0 'cleanup disarm of the first'
  run --id ipv6-2 disarm
  expect_rc 0 'cleanup disarm of the second'
  SS_TUPLE=$saved_tuple
  printf '%s\n' "${SS_ROWS[0]}" >"$SSTABLE"
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
  expect_out_matching 'left=[0-9]+m[0-9][0-9]s' 'status counts down in minutes'
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
  # The snapshot is a placeholder naming the command, not the output of a command
  # that ran: this is the file a real rollback would load into nft.
  expect_file_contains "$(session_dir nft)/snapshots/20-nftables/ruleset.nft" \
    'DRYRUN nft list ruleset' 'the captured ruleset is a dry-run placeholder'
  run --id nft disarm --purge
  expect_rc 0 'cleanup disarm --purge'
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
  expect_out_matching 'has [0-9]+m[0-9][0-9]s and no watchdog, starting a new one' \
    'the restart is logged'
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
  expect_trace_count 'restore ' 1 'only the captured hook was restored'
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
test_hook_names_cannot_escape_the_directory
test_stored_hook_names_are_contained_at_recover
test_help_and_hooks
test_shellcheck_if_present
test_arm_captures_snapshots
test_options_reach_the_hook
test_hooks_see_the_library_in_every_process
test_dry_run_prints_privileged_commands
test_positional_id_is_accepted
test_confirm_stops_the_switch
test_double_arm_is_refused
test_failed_snapshot_aborts_before_the_change
test_interrupted_capture_rolls_back
test_skipped_hook_is_not_restored
test_grace_cuts_the_deadline_short
test_socket_probe_reads_either_layout
test_socket_loss_cuts_the_deadline
test_unreadable_socket_is_not_a_gone_session
test_probe_degrades_to_the_timer
test_ipv6_tuple_falls_back_to_the_timer
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
