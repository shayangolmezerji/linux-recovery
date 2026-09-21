# shellcheck shell=bash
# Shared helpers for deadman-ssh and the rollback hooks in hooks.d/.
# This file is sourced, never executed. Everything a hook needs to change the
# host goes through dm_priv, which is the single place dry-run mode intercepts.

# ISO-8601 UTC, so timestamps in the log sort the way they read.
dm_now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

dm_now() { date +%s; }

dm_log() { printf '%s %s\n' "$(dm_now_iso)" "$*"; }

dm_warn() { printf '%s WARN %s\n' "$(dm_now_iso)" "$*" >&2; }

# Hooks report "this host has nothing for me to do" with exit code 77, which
# keeps a missing tool from looking like a failed rollback.
DM_EX_SKIP=77

dm_die() {
  printf 'deadman: %s\n' "$*" >&2
  exit 1
}

dm_is_dry_run() {
  case "${DEADMAN_DRY_RUN:-}" in
  1 | true | TRUE | yes | YES) return 0 ;;
  *) return 1 ;;
  esac
}

# Renders an argv list the way a shell would read it back.
dm_quote() {
  local rendered='' arg
  for arg in "$@"; do
    rendered+=$(printf '%q ' "$arg")
  done
  printf '%s\n' "${rendered% }"
}

# The privilege escalator is a list of words, not a string to eval, so a runner
# with an argument containing a space is refused rather than guessed at.
dm_runner_argv() {
  local -a words
  read -r -a words <<<"${DEADMAN_RUNNER:-sudo -n}"
  printf '%s\n' "${words[@]}"
}

# dm_priv <command> [args...]: the only path to the host. Dry-run prints the
# exact argv and succeeds without touching anything.
dm_priv() {
  local -a runner
  if dm_is_dry_run; then
    dm_log "DRY-RUN $(dm_quote "$@")"
    return 0
  fi
  mapfile -t runner < <(dm_runner_argv)
  dm_log "EXEC $(dm_quote "${runner[@]}" "$@")"
  "${runner[@]}" "$@"
}

# Same as dm_priv but feeds a file on stdin. Used to write back a snapshot.
dm_priv_in() {
  local src="$1"
  shift
  local -a runner
  if dm_is_dry_run; then
    dm_log "DRY-RUN $(dm_quote "$@") < $src"
    return 0
  fi
  mapfile -t runner < <(dm_runner_argv)
  dm_log "EXEC $(dm_quote "${runner[@]}" "$@") < $src"
  "${runner[@]}" "$@" <"$src"
}

# dm_capture <file> <command> [args...]: records a read-only query. In dry-run
# mode there is no real output to read, so the file gets a placeholder naming
# the command that would have produced it.
dm_capture() {
  local file="$1"
  shift
  if dm_is_dry_run; then
    printf 'DRYRUN %s\n' "$(dm_quote "$@")" >"$file"
    dm_log "DRY-RUN capture $(basename "$file") <= $(dm_quote "$@")"
    return 0
  fi
  local -a runner
  mapfile -t runner < <(dm_runner_argv)
  dm_log "EXEC capture $(basename "$file") <= $(dm_quote "${runner[@]}" "$@")"
  "${runner[@]}" "$@" >"$file"
}

# Field n of the first line of a snapshot, or a marker when the snapshot is a
# dry-run placeholder and the real value is not knowable yet.
dm_capture_field() {
  local file="$1" index="$2" first
  if [[ ! -s $file ]]; then
    printf '%s\n' '<empty-snapshot>'
    return 0
  fi
  IFS= read -r first <"$file" || true
  if [[ $first == DRYRUN* ]]; then
    printf '%s\n' '<from-snapshot>'
    return 0
  fi
  awk -v n="$index" 'NR == 1 { print $n }' "$file"
}

dm_require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      dm_log "SKIP $1: not installed"
      exit "$DM_EX_SKIP"
    }
  done
}

dm_pid_alive() {
  local pid="$1"
  [[ -n $pid ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# Reads the kernel boot id. A change between arm and recover is how the switch
# tells "the watchdog was killed" from "the machine rebooted".
dm_boot_id() {
  local file="${DEADMAN_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
  if [[ -r $file ]]; then
    cat "$file"
  else
    printf 'unknown\n'
  fi
}

dm_state_dir() {
  printf '%s\n' "${DEADMAN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/deadman-ssh}"
}

dm_session_dir() {
  printf '%s\n' "$(dm_state_dir)/sessions/$1"
}

dm_state_file() {
  printf '%s\n' "$(dm_session_dir "$1")/state"
}

dm_state_get() {
  local file="$1" key="$2" line
  [[ -f $file ]] || return 1
  line=$(grep -m1 "^$key=" "$file" 2>/dev/null) || return 1
  printf '%s\n' "${line#*=}"
}

# Rewritten through a temp file so a watchdog reading mid-update never sees a
# half-written deadline.
dm_state_set() {
  local file="$1" key="$2" value="$3" line tmp
  tmp="$file.tmp.$$"
  : >"$tmp"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == "$key="* ]] && continue
    printf '%s\n' "$line" >>"$tmp"
  done <"$file"
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  mv -f "$tmp" "$file"
}

# 300, 5m, 2h, 1d -> seconds. Anything else is a usage error.
dm_parse_ttl() {
  local raw="$1"
  if [[ ! $raw =~ ^([0-9]+)([smhd]?)$ ]]; then
    return 1
  fi
  local number="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
  case "$unit" in
  s | '') printf '%s\n' "$number" ;;
  m) printf '%s\n' "$((number * 60))" ;;
  h) printf '%s\n' "$((number * 3600))" ;;
  d) printf '%s\n' "$((number * 86400))" ;;
  esac
}

# Formats a countdown for `status`. Negative means overdue.
dm_duration() {
  local seconds="$1" sign='' abs
  if ((seconds < 0)); then
    sign='-'
    abs=$(( -seconds ))
  else
    abs=$seconds
  fi
  printf '%s%dm%02ds\n' "$sign" $((abs / 60)) $((abs % 60))
}
