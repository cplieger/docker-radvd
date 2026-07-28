#!/usr/bin/env bash
# Shared harness for a repo's shell unit tests — CANONICAL COPY in cplieger/ci
# (configs/shell/lib.sh), synced to each adopting repo's tests/shell/lib.sh
# by scripts/classify-repos.py (a repo enrolls by committing a tests/shell/run.sh,
# which is also what the shell-ci hook looks for). DO NOT edit the synced copy in
# an app repo — change it here and let the sync land it.
#
# WHY THESE SUITES EXIST, generically: an image smoke test proves the assembled
# image boots, so it can only ever walk the paths a HEALTHY container takes. The
# branches that matter most are the ones that fail CLOSED — a refusal, a guard, a
# fallback — and a healthy image never reaches them. These suites assert what
# happens when it should NOT work. Each repo's own rationale (which of its shell
# files are covered, and what its existing tests already own) belongs in its
# repo-owned tests/shell/run.sh header, not here.
#
# HOW: each test EXTRACTS one function verbatim out of the shipped shell and runs
# it against temp directories, stubbing only what spawns a process or touches the
# host. Nothing is reimplemented — an assertion against a paraphrase proves nothing
# about what ships. That requires the function under test to take its inputs as
# arguments or environment rather than hardcoding paths; where it does not, the
# honest answer is to leave it uncovered rather than to restructure shipped
# behaviour for the test's benefit.
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
# The PID guard is load-bearing, not defensive: only the process that INSTALLED the
# trap may act on it. Without it, a child that reaches this handler runs it with the
# parent's $WORK and _reported=0 — printing a spurious forgot-report error and
# `rm -rf`-ing the parent's live scratch dir mid-run. Measured on the radvd latch
# suite before the guard: the error fired on 26 of 30 cases and a canary in $WORK
# was deleted on the first iteration.
#
# That symptom is real; the MECHANISM originally recorded here was not. This comment
# claimed an async child (`cmd &`) INHERITS the EXIT trap while `( )` and `$( )`
# reset it. Re-measured 2026-07 on bash 5.2.37, nothing tested inherits it: not a
# backgrounded function (returning, exiting, or failing its `exec` — the radvd stub's
# exact shape), not a backgrounded subshell, builtin or external, and not a plain
# subshell, command substitution, or pipeline segment. So the construct that actually
# reached the handler is unconfirmed, and a reader should not build on the old model.
# The guard stays because its contract holds regardless of which construct triggers
# it, and harness_test.sh now pins that contract directly by invoking this handler
# from a differing BASHPID rather than by trying to reproduce the trigger.
#
# The owner is recorded as ${BASHPID:-$$}, not $$: inside a `( ... )` subshell $$ is
# still the OUTER shell's pid, so a suite that sources this file inside a subshell
# would install the trap while recording a pid that is not its own — and then the
# handler's own guard would disable it in the very process that installed it. Both
# duties silently stopped: the forgot-report guard never fired and $WORK leaked
# (measured 2026-07 with `bash -c '( . lib.sh; new_workdir; ok x )'`, which exited 0
# with the scratch dir still on disk). BASHPID needs bash >= 4.0; on an older bash the
# `:-$$` fallback degrades to the original behaviour rather than erroring, which is the
# right trade here (the CI runners and every dev box in the fleet are bash 5).
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
