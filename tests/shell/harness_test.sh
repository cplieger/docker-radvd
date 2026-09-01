#!/usr/bin/env bash
# CANONICAL COPY in cplieger/ci (configs/shell/harness_test.sh), synced to each
# adopting repo's tests/shell/ alongside lib.sh. Never edit the synced copy in an
# app repo — change it here and let the sync land it.
#
# SC2015: `cond && ok || no` cannot mis-fire, because lib.sh's ok/no/skip return 0
# unconditionally by design.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# A self-test must not report its verdict through its own subject: with no()'s
# `_fail=$((_fail + 1))` neutralised this file printed "FAIL failure passthrough"
# and still exited 0 with "0 failed". So wrap the REAL no() (`declare -f` rename,
# never a copy, which would drift from the original's output format) and tally
# independently; the verdict below fails if EITHER tally says fail.
_self_fail=0
_lib_no_def=$(declare -f no)
eval "_lib_no${_lib_no_def#no}"
no() {
  _self_fail=$((_self_fail + 1))
  _lib_no "$@"
}

# The pinned assertion total, checked against report's own summary in the verdict
# block below. Three different expected counts (the child fixtures' 3 passes and 2
# skips, and this) cannot all be satisfied by a counter mutated to a CONSTANT, and
# the check also proves this file ran every assertion instead of exiting early.
# Update it deliberately when adding a case.
_EXPECTED_ASSERTIONS=20

LIB="$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

# The fixture: one of each shape the extractor documents.
FIXTURE="$WORK/fixture.sh"
cat >"$FIXTURE" <<'FIX'
#!/usr/bin/env bash
ordinary() {
  echo one
  echo two
}
subshell_bodied() (
  cd /tmp || exit 1
  echo isolated
)
one_liner() { echo tiny; }
one_liner_commented() { echo tiny; } # trailing note
one_line_subshell() ( echo tiny )
opener_commented() { # note on the opener
  echo two lines
}
next_victim() {
  echo "must never be swept into a neighbour's extraction"
}
malformed() {
  fi
}
FIX

ENTRYPOINT="$FIXTURE"

# defs FILE -> number of function definitions in an extraction
defs() {
  grep -cE '^[a-z_]+\(\) *[({]' "$1"
}

# --- 1. the four documented shapes each extract as EXACTLY one definition ---------
for fn in ordinary subshell_bodied one_liner one_liner_commented one_line_subshell opener_commented; do
  src=$(extract_function "$fn") || exit 1
  [ "$(defs "$src")" -eq 1 ] && ! grep -q next_victim "$src" \
    && ok "$fn extracts alone ($(wc -l <"$src") lines, 1 definition)" \
    || no "$fn extraction" "defs=$(defs "$src"), over-capture: $(grep -c next_victim "$src") next_victim lines"
done

src=$(extract_function subshell_bodied) || exit 1
[ "$(tail -1 "$src")" = ")" ] && bash -n "$src" 2>/dev/null \
  && ok "subshell-bodied extraction closes on ')' and parses" \
  || no "subshell close" "last line: '$(tail -1 "$src")'"

# --- 2. a missing function is FATAL through load_function --------------------------
# The `; true` is the whole assertion: without it the subshell's status IS
# load_function's, so a version that merely RETURNED non-zero and let the caller
# carry on would be indistinguishable from one that exited.
(
  load_function does_not_exist
  true
) 2>/dev/null
rc=$?
[ "$rc" -ne 0 ] \
  && ok "load_function of a missing function TERMINATES the process (rc=$rc), it does not return" \
  || no "missing-function fatality" "load_function returned instead of exiting; a real test file would carry on with the function undefined"

# --- 3. a malformed extraction is FATAL through load_function ----------------------
# extract_function succeeds (the text exists); the SOURCE then raises a syntax error,
# which `.` does not turn fatal on its own without set -e. Same sentinel.
(
  load_function malformed
  true
) 2>/dev/null
rc=$?
[ "$rc" -ne 0 ] \
  && ok "sourcing a malformed extraction TERMINATES the process (rc=$rc), not a skipped definition" \
  || no "malformed-source fatality" "load_function returned after a failed source; the function is undefined and the file continues"

# --- 4. a bad ENTRYPOINT names itself instead of extracting nothing ----------------
(ENTRYPOINT=/nonexistent-entrypoint.sh extract_function ordinary) 2>"$WORK/err" >/dev/null
rc=$?
[ "$rc" -ne 0 ] && grep -q 'ENTRYPOINT is not a readable file' "$WORK/err" \
  && ok "a bad ENTRYPOINT is fatal and the error names the path" \
  || no "bad ENTRYPOINT" "rc=$rc, err: $(cat "$WORK/err")"

# --- 5. a test file that forgets report cannot exit green --------------------------
# ok/no return 0 by design, so nothing but the harness EXIT trap stands between a
# lost report line and a false green.
bash -c '
  set -u
  . "$1"
  new_workdir >/dev/null
  ok "recorded but never reported" >/dev/null
' _ "$LIB" >/dev/null 2>"$WORK/err"
rc=$?
[ "$rc" -eq 70 ] && grep -q 'exited without calling report' "$WORK/err" \
  && ok "exiting without report is a loud harness error (rc=70), never a pass" \
  || no "forgot-report guard" "rc=$rc, err: $(cat "$WORK/err")"

bash -c '
  set -u
  . "$1"
  new_workdir >/dev/null
  ok "one pass" >/dev/null
  report >/dev/null
' _ "$LIB" 2>/dev/null
rc=$?
[ "$rc" -eq 0 ] \
  && ok "a reporting file keeps its verdict (rc=0)" \
  || no "report passthrough" "rc=$rc"

bash -c '
  set -u
  . "$1"
  new_workdir >/dev/null
  no "one failure" "deliberate" >/dev/null
  report >/dev/null
' _ "$LIB" 2>/dev/null
rc=$?
[ "$rc" -ne 0 ] && [ "$rc" -ne 70 ] \
  && ok "a failing file keeps its non-zero verdict through the EXIT trap (rc=$rc)" \
  || no "failure passthrough" "rc=$rc"

# --- 6. the tally actually counts, and a skip is not a pass ------------------------
# Three passes and two skips, not one or two of each: a counter mutated to a CONSTANT
# satisfies any fixture whose expected value happens to equal that constant. The
# child's STATUS is captured alongside its output as well, because a report that
# started failing on a non-zero skip count would make every honestly-skipping suite
# red in CI while this self-test stayed green.
out=$(bash -c '
  set -u
  . "$1"
  new_workdir >/dev/null
  ok "first" >/dev/null
  ok "second" >/dev/null
  ok "third" >/dev/null
  report
' harness-child "$LIB" 2>/dev/null)
rc=$?
# Anchored to the WHOLE summary line: a wrong count in any field must fail rather
# than match a substring of a longer tally.
printf '%s\n' "$out" | grep -qx 'harness-child: 3 passed, 0 failed' \
  && [ "$rc" -eq 0 ] \
  && ok "the tally counts passes exactly (three ok calls report as 3 passed, rc=0)" \
  || no "pass tally" "rc=$rc, report said: $(printf '%s' "$out" | tr '\n' ' ')"

# A skip folded into _pass would show 5 passed, and a skip that counted nothing would
# drop the third field entirely.
out=$(bash -c '
  set -u
  . "$1"
  new_workdir >/dev/null
  ok "one" >/dev/null
  ok "two" >/dev/null
  ok "three" >/dev/null
  skip "premise A" "cannot hold here" >/dev/null
  skip "premise B" "cannot hold here either" >/dev/null
  report
' harness-child "$LIB" 2>/dev/null)
rc=$?
printf '%s\n' "$out" | grep -qx 'harness-child: 3 passed, 0 failed, 2 skipped' \
  && ok "skips are counted separately and never folded into the pass count" \
  || no "skip tally" "rc=$rc, report said: $(printf '%s' "$out" | tr '\n' ' ')"

# Honest skips are not failures: report must still exit 0, or every uid-gated skip
# would turn CI red.
[ "$rc" -eq 0 ] \
  && ok "a suite containing honest skips still exits 0 (skips are not failures)" \
  || no "skip status" "report exited $rc on a suite with 2 skips and 0 failures"

# A second skip fixture at a different count: one fixture pins a NUMBER, not a tally,
# and this file records no skips of its own, so nothing else contradicts a constant.
out=$(bash -c '
  set -u
  . "$1"
  new_workdir >/dev/null
  ok "only pass" >/dev/null
  skip "sole premise" "cannot hold here" >/dev/null
  report
' harness-child "$LIB" 2>/dev/null)
printf '%s\n' "$out" | grep -qx 'harness-child: 1 passed, 0 failed, 1 skipped' \
  && ok "the skip tally counts (one skip reports as 1 skipped, not the previous 2)" \
  || no "single skip tally" "report said: $(printf '%s' "$out" | tr '\n' ' ')"

# --- 7. only the process that installed the EXIT trap may act on it ----------------
# Without the PID guard a child that reaches the handler scrubs the PARENT's live
# scratch dir mid-run and prints a spurious forgot-report error. Probed by invoking
# the handler directly from a subshell — a different BASHPID is the whole
# precondition — because `cmd &` does NOT inherit an EXIT trap in bash 5.2, so a
# background-job fixture would assert nothing.
touch "$WORK/pid-guard-canary"
guard_out=$( (_lib_on_exit) 2>&1)
guard_rc=$?
[ "$guard_rc" -eq 0 ] && [ -z "$guard_out" ] && [ -f "$WORK/pid-guard-canary" ] \
  && ok "the EXIT handler no-ops in a process that did not install it" \
  || no "trap PID guard" "rc=$guard_rc, output='$guard_out', canary present=$([ -f "$WORK/pid-guard-canary" ] && echo yes || echo NO)"

# --- 8. which refusal fires when two guards are redundant --------------------------
# load_function's `|| exit 1` and its source-failure fatal are REDUNDANT for a missing
# function (with src empty, `.` fails on the empty string and the second guard still
# kills the process), so section 2's outcome assertion cannot tell them apart. Assert
# WHICH refusal fired.
(
  load_function does_not_exist
  true
) 2>"$WORK/lf-err" >/dev/null
grep -q 'could not extract does_not_exist()' "$WORK/lf-err" \
  && ! grep -q 'sourcing the extraction' "$WORK/lf-err" \
  && ok "a missing function dies at the extract guard, never reaching the source guard" \
  || no "load_function guard identity" "stderr: $(tr '\n' '|' <"$WORK/lf-err")"

# --- 9. extract_range is fatal on a miss too ---------------------------------------
# Same false-green class as extract_function: an empty range would source nothing and
# report every assertion as passing.
(extract_range 'NO_SUCH_START_MARKER' 'NO_SUCH_END_MARKER') 2>"$WORK/er-err" >/dev/null
rc=$?
[ "$rc" -ne 0 ] \
  && grep -q 'could not extract range' "$WORK/er-err" \
  && grep -q 'NO_SUCH_START_MARKER..NO_SUCH_END_MARKER' "$WORK/er-err" \
  && ok "an empty extract_range is fatal (rc=$rc) and the error names both markers" \
  || no "extract_range fatality" "rc=$rc, err: $(cat "$WORK/er-err")"

# --- the verdict -------------------------------------------------------------------
# report is one of the SUBJECTS here, so it runs in a SUBSHELL with its output
# captured: mutating report's final status test to `exit 0` ended THIS process from
# inside report, and the independent tally below never ran. The summary is the only
# thing a CI log shows and report ignores its own printf status (a full filesystem
# lost every line and still exited 0), hence the re-emit and the non-empty check. The
# exit status is the OR of report's verdict, the _self_fail tally, and the summary
# having actually reached the log.
_summary="$WORK/summary"
_rc=0
(report) >"$_summary" 2>&1 || _rc=1
_emitted=0
cat "$_summary" && _emitted=1
if [ "$_emitted" -ne 1 ] || [ ! -s "$_summary" ]; then
  printf 'harness_test.sh: the summary never reached the log (emitted=%d, %d bytes captured)\n' \
    "$_emitted" "$(wc -c <"$_summary" 2>/dev/null || echo 0)" >&2
  _rc=1
fi
# The pinned total is the assertion that survives deletion of the two checks above and
# of the _self_fail block below: each of those, deleted alone, re-opened a false green.
if ! grep -qx "harness_test.sh: $_EXPECTED_ASSERTIONS passed, 0 failed" "$_summary"; then
  printf 'harness_test.sh: summary is not "%d passed, 0 failed" — an assertion failed, a lib.sh counter is wrong, or this file exited early\n' \
    "$_EXPECTED_ASSERTIONS" >&2
  _rc=1
fi
if [ "$_self_fail" -ne 0 ]; then
  [ "$_rc" -eq 0 ] && printf 'harness_test.sh: %d failure(s) that report did NOT count — lib.sh counting is broken\n' "$_self_fail" >&2
  _rc=1
fi

# One compound line on purpose: split across lines, deleting only the final
# `exit "$_rc"` left the file green with lib.sh's failure counting broken; as one line,
# deleting it leaves _reported at 0 and the EXIT trap turns this file's silence into a
# loud rc=70 instead.
_reported=1 && rm -rf "$WORK" && trap - EXIT && exit "$_rc"
