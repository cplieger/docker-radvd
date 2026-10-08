#!/usr/bin/env bash
# Synced from cplieger/ci/configs/shell/lib.sh. Change it there.
# Shared harness for a repo's shell unit tests. A repo enrolls by committing
# tests/shell/run.sh, whose header carries that repo's scope rationale.
# Each test extracts a shipped function verbatim and runs it against stubs:
# an assertion against a paraphrase proves nothing about what ships, and the
# fail-closed branches worth testing are ones a healthy smoke run never takes.
# Sourced by every tests/shell/*_test.sh via the runner; not executable itself.

# The repo root, derived from this file's own location so a test behaves the same
# whether the runner, CI, or a developer in another directory invokes it.
TESTS_SHELL_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_SHELL_DIR/../.." && pwd)
# Overridable so a red-check can point a test at a mutated /tmp copy, and not
# readonly so a suite whose shipped shell spans several files can reassign it
# before each extraction. Every extract validates the current value.
ENTRYPOINT="${ENTRYPOINT:-$REPO_ROOT/entrypoint.sh}"

_pass=0
_fail=0
_skip=0
_reported=0

# One EXIT trap scrubs $WORK and fails a file that never called report: ok/no
# return 0, so a lost final `report` line would otherwise exit 0 as a clean pass.
# Only the process that installed the trap may act on it, or a child reaching the
# handler prints a spurious error and deletes the parent's live $WORK
# (harness_test.sh pins this from a differing BASHPID). The owner is
# ${BASHPID:-$$}, not $$, because $$ inside `( ... )` is the outer shell's pid and
# would disarm the trap in the subshell that installed it. BASHPID needs bash 4+.
_LIB_OWNER_PID=${BASHPID:-$$}
_lib_on_exit() {
  _lib_status=$?
  [ "${BASHPID:-$$}" = "$_LIB_OWNER_PID" ] || return 0
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  if [ "$_reported" -eq 0 ]; then
    printf 'harness error: %s exited without calling report\n' "$(basename "$0")" >&2
    exit 70
  fi
  exit "$_lib_status"
}
trap _lib_on_exit EXIT

# ok/no are the whole assertion vocabulary: a test states what it verified in the
# same words the failure would use, so a CI log reads as a list of guarantees.
# Both RETURN 0 unconditionally, and that is load-bearing rather than tidy: the
# tests read `[ cond ] && ok "..." || no "..."`, which shellcheck flags (SC2015)
# because in general the `||` branch also runs when the middle command fails.
# Pinning the status here makes that impossible, so each test file disables SC2015
# against this guarantee instead of against an assumption.
ok() {
  _pass=$((_pass + 1))
  printf 'ok   %s\n' "$1"
  return 0
}

no() {
  _fail=$((_fail + 1))
  printf 'FAIL %s -- %s\n' "$1" "$2"
  return 0
}

# skip <what> <why>
#
# For an assertion whose premise cannot hold here, such as a `[ -r "$f" ]`
# refusal under root, which reads a chmod-000 file. Counted separately and never
# as a pass, so a suite that skips everything cannot read as green. Returns 0 for
# the same reason ok/no do.
skip() {
  _skip=$((_skip + 1))
  printf 'skip %s -- %s\n' "$1" "$2"
  return 0
}

# Every extract reads $ENTRYPOINT, which a test may have just reassigned; a
# mistyped or stale path must name itself here rather than reaching sed and
# surfacing as an indistinguishable empty extraction.
_require_entrypoint() {
  [ -f "$ENTRYPOINT" ] && [ -r "$ENTRYPOINT" ] && return 0
  printf 'harness error: ENTRYPOINT is not a readable file: %s\n' "$ENTRYPOINT" >&2
  exit 1
}

# extract_function <name> [dest]
#
# Copies one function's source out of $ENTRYPOINT and prints the path it wrote.
# The body ends at a column-0 `}` or `)`, which shfmt -i 2 -ci -bn guarantees;
# `)` closes a subshell-bodied `fn() (`, which a `}`-only scan would silently run
# past into the next function. A one-line definition is emitted alone. A miss is
# fatal, because sourcing nothing passes every assertion; reach that fatal
# through load_function.
extract_function() {
  local name=$1 dest=${2:-$WORK/$1.sh}
  _require_entrypoint
  awk -v fn="$name" '
    !inside && index($0, fn "()") == 1 {
      print
      # Opener vs one-liner is decided by the bracket the line ENDS on, ignoring a
      # trailing comment, opener first: `fn() { # note` contains the `)` of the
      # parameter list, so a closer-first test would mistake it for a whole body.
      if ($0 ~ /[({][[:space:]]*(#.*)?$/) { inside = 1; next }
      if ($0 ~ /[)}][[:space:]]*(#.*)?$/) exit
      inside = 1
      next
    }
    inside {
      print
      if ($0 ~ /^[)}][[:space:]]*$/) exit
    }
  ' "$ENTRYPOINT" >"$dest"
  if [ ! -s "$dest" ]; then
    printf 'harness error: could not extract %s() from %s\n' "$name" "$ENTRYPOINT" >&2
    exit 1
  fi
  printf '%s\n' "$dest"
}

# load_function <name> [dest]
#
# extract_function plus the source; the only safe spelling of that pair.
# `. "$(extract_function x)"` is broken: the fatal exit kills only the command
# substitution, `.` fails on the empty path, and without set -e the file carries
# on with the function undefined, so every "guard did not fire" case passes.
load_function() {
  local src
  src=$(extract_function "$@") || exit 1
  # The path is generated, so shellcheck cannot follow it. A failed source is
  # fatal too: without set -e a syntax error would leave the function undefined.
  # shellcheck disable=SC1090
  . "$src" || {
    printf 'harness error: sourcing the extraction of %s failed\n' "$1" >&2
    exit 1
  }
}

# extract_range <start-regex> <end-regex> [dest]
#
# The block form, for logic that lives inline in the boot path rather than in a
# function (the APT_PACKAGES block). Same fatal-on-miss rule, and the same
# reachability caveat: capture it as `x=$(extract_range ...) || exit 1`, never as a
# bare `. "$(extract_range ...)"`.
extract_range() {
  local start=$1 end=$2 dest=${3:-$WORK/range.sh}
  _require_entrypoint
  sed -n "/$start/,/$end/p" "$ENTRYPOINT" >"$dest"
  if [ ! -s "$dest" ]; then
    printf 'harness error: could not extract range %s..%s from %s\n' \
      "$start" "$end" "$ENTRYPOINT" >&2
    exit 1
  fi
  printf '%s\n' "$dest"
}

# A private scratch directory per test process, removed on exit including on a
# failed assertion, so a run leaves nothing behind in /tmp. The removal lives in
# the harness's single EXIT trap (installed above); installing one here would
# silently REPLACE that trap and with it the forgot-report guard.
new_workdir() {
  WORK=$(mktemp -d)
  printf '%s\n' "$WORK"
}

# Prints the tally and sets the process exit status. Every test file ends with
# this, and the runner reads the status rather than parsing output — the EXIT
# trap above turns a missing report call into a loud harness error. Skips are
# reported separately and never fold into the pass count: a suite whose premises
# all went unmet must not read as a suite that verified them.
report() {
  _reported=1
  if [ "$_skip" -ne 0 ]; then
    printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$_pass" "$_fail" "$_skip"
  else
    printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$_pass" "$_fail"
  fi
  [ "$_fail" -eq 0 ]
}
