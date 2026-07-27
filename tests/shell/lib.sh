#!/usr/bin/env bash
# Shared harness for the entrypoint.sh unit tests.
#
# WHY THESE TESTS EXIST, and why they are neither of the two smoke tests: 118 of
# entrypoint.sh's 260 lines are a hand-written radvd-config validator (comment-
# stripped directive gates plus an awk block-scanner), and its consequential
# branches are warn-only guards a healthy container never shows: a config that
# cannot be scanned, an AdvRASrcAddress pointing at a global VIP whose RAs every
# host silently discards (RFC 4861 §6.1.2), a commented-out IgnoreIfMissing that
# looks configured. tests/smoke.sh (Dockerfile test stage) asserts the radvd
# BINARY; scripts/smoke.sh asserts the supervisor's signal contract against a real
# container. Neither can reach the validator's individual arms, nor the pre-pid
# signal latch, which no container test hits deterministically. These do.
#
# HOW: each test extracts the real code verbatim from the shipped entrypoint.sh
# and runs it against temp directories, with the one external command it touches
# (radvd itself) stubbed. Nothing is reimplemented here — an assertion that passed
# against a paraphrase would prove nothing about what ships. The validator reads
# its config path from the CONF global (a plain assignment, not readonly), which
# is what makes this possible without a container or a real /etc/radvd.
#
# Sourced by every tests/shell/*_test.sh via the runner; not executable itself.

# The repo root, derived from this file's own location so a test behaves the same
# whether the runner, CI, or a developer in another directory invokes it.
TESTS_SHELL_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_SHELL_DIR/../.." && pwd)
# Overridable so a test can be pointed at an older revision of the file (the
# red-check a maintainer runs when adding a case: extract the previous
# entrypoint.sh to /tmp and confirm the new assertion actually fails against it).
#
# Deliberately NOT readonly, and reassignable mid-file: a repo whose shipped shell
# spans several files (an entrypoint plus sourced helpers) points ENTRYPOINT at each
# one in turn before extracting from it. Every extract validates the current value,
# so a stale or mistyped path names itself instead of surfacing as an empty
# extraction.
ENTRYPOINT="${ENTRYPOINT:-$REPO_ROOT/entrypoint.sh}"

_pass=0
_fail=0
_skip=0
_reported=0

# One EXIT trap owns both end-of-process duties: scrub the scratch dir, and
# refuse to let a test file end without calling report. ok/no record failures but
# deliberately return 0 (see below), so a file whose final `report` line was lost
# would otherwise exit 0 after its last assertion and the runner would count a
# clean pass — a complete false green from a one-line deletion.
#
# The PID guard is load-bearing, not defensive. Command substitutions and `( )`
# subshells do reset the EXIT trap, but an ASYNC child (`cmd &`) INHERITS it: a
# stubbed background process that dies before its exec would otherwise run this
# handler with the parent's $WORK and _reported=0 — printing a spurious
# forgot-report error and `rm -rf`-ing the parent's live scratch dir mid-run.
# Measured on the radvd latch suite before this guard: the error fired on 26 of 30
# cases and a canary in $WORK was deleted on the first iteration. Only the process
# that INSTALLED the trap may act on it.
_LIB_OWNER_PID=$$
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
# For an assertion whose PREMISE does not hold in this environment rather than one
# that failed. The case exists here because some guards are unreachable for some
# callers: root reads a chmod-000 file, so a `[ -r "$f" ]` refusal cannot be
# provoked as root, and asserting it anyway fails for a maintainer running as root
# while passing on the non-root CI runner -- a per-user false failure, which is
# worse than an honest gap. Counted separately and never as a pass, so a suite that
# quietly skips everything cannot read as green. Returns 0 for the same reason
# ok/no do (see their comment above).
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
# Copies one function's source out of $ENTRYPOINT so it can be sourced in
# isolation, and prints the path it wrote.
#
# The body's end is found by scanning for a line that is exactly `}` or `)` in
# column 0, which shfmt -i 2 -ci -bn guarantees and the repo's own format gate
# enforces -- so a reformat that broke this would fail CI on the shipped file, not
# silently here. Both closers matter: a SUBSHELL-bodied function (`fn() (`, which
# entrypoint.sh uses for install_kiro_cli so its cd and traps cannot leak) closes
# with `)`, and a `}`-only scan runs straight past it into whatever follows. That
# over-capture is silent, because the result still parses and still defines the
# function asked for -- it just also redefines the next one or two, which is how a
# test starts asserting against something it never named.
#
# A one-line definition (`fn() { cmd; }`) is closed by its own opening line, so it
# is emitted alone rather than swept forward to the next function's closing brace.
#
# A miss is fatal rather than an empty source: a test that sources nothing would
# report every assertion as passing against a function that never ran. Reach that
# fatal through load_function, or by checking the status -- see its comment.
extract_function() {
  local name=$1 dest=${2:-$WORK/$1.sh}
  _require_entrypoint
  awk -v fn="$name" '
    !inside && index($0, fn "()") == 1 {
      print
      # Decide opener-vs-one-liner by which bracket the line ENDS on, ignoring a
      # trailing comment. An opener ends on `{` or `(`; a one-liner ends on `}` or
      # `)`. Testing the opener first matters: `fn() { # note` contains a `)` from the
      # parameter list, so a closer-only test could mistake it for a complete body.
      #
      # The `)` form is not hypothetical in one direction and is gate-prevented in
      # the other: entrypoint files really do carry multi-line subshell bodies
      # (`install_kiro_cli() (`), while shfmt -i 2 -ci -bn rewrites a ONE-line
      # subshell, so that shape cannot reach a formatted repo. Handled anyway rather
      # than resting on the format gate.
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
# extract_function plus the source, and the ONLY safe way to spell that pair.
#
# `. "$(extract_function x)"` reads naturally and is broken: the fatal `exit 1`
# runs inside the command substitution, so it kills that subshell and nothing
# else. The substitution yields the empty string, `.` fails on it, and with no
# `set -e` the test file CARRIES ON with the function undefined -- every assertion
# that expects a guard NOT to fire then passes, because nothing ran at all.
# Measured on this suite: 5 of 10 assertions reported ok against a function that
# did not exist. Here the status of the assignment is the subshell's, so the
# refusal reaches the test process.
load_function() {
  local src
  src=$(extract_function "$@") || exit 1
  # The path is generated above, so there is nothing on disk for shellcheck to
  # follow at lint time. The source itself must be fatal too: a malformed
  # extraction raises a syntax error but `.` does not stop a non-interactive
  # shell without set -e, and the file would carry on with the function
  # undefined or half-defined — the same false-green class the extract guard
  # closes.
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
