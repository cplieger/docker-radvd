#!/usr/bin/env bash
# The harness testing itself — CANONICAL COPY in cplieger/ci
# (configs/shell/harness_test.sh), synced to each adopting repo's
# tests/shell/harness_test.sh alongside lib.sh. DO NOT edit the synced copy in an
# app repo — change it here and let the sync land it.
#
# Extraction shapes, fatal reachability, and the forgot-report guard.
#
# Every other file in this directory trusts lib.sh for one load-bearing property:
# a test that failed to load real code CANNOT keep running and report passes.
# That property broke once (the fatal died inside a command substitution and five
# assertions passed against a function that did not exist), so it is pinned here
# against a fixture file rather than assumed. The fixture covers every function
# shape the extractor claims to handle; entrypoint.sh is deliberately not the
# subject, so this file is identical in every repo that adopts the pattern.
#
# Lint directives, each against a stated guarantee rather than an assumption:
#   SC2015 - the `cond && ok || no` form cannot mis-fire, because lib.sh's
#     ok/no/skip return 0 unconditionally by design (see their comments).
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

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

# The subshell body must end on its own ')' and still parse.
src=$(extract_function subshell_bodied) || exit 1
[ "$(tail -1 "$src")" = ")" ] && bash -n "$src" 2>/dev/null \
  && ok "subshell-bodied extraction closes on ')' and parses" \
  || no "subshell close" "last line: '$(tail -1 "$src")'"

# --- 2. a missing function is FATAL through load_function --------------------------
# The `; true` is the whole assertion. Without it the subshell's status IS
# load_function's status, so a version that merely RETURNED non-zero and let the
# caller carry on would be indistinguishable from one that exited — and carrying on
# is exactly the historical defect (the fatal died inside $(...) and five assertions
# passed against a function that did not exist). With the sentinel, the subshell
# exits 0 unless load_function really terminated the process.
(
  load_function does_not_exist
  true
) 2>/dev/null
rc=$?
[ "$rc" -ne 0 ] \
  && ok "load_function of a missing function TERMINATES the process (rc=$rc), it does not return" \
  || no "missing-function fatality" "load_function returned instead of exiting; a real test file would carry on with the function undefined"

# --- 3. a malformed extraction is FATAL through load_function ----------------------
# extract_function succeeds (the text exists); the SOURCE then raises a syntax
# error, which `.` does not turn fatal on its own without set -e. Same sentinel, for
# the same reason.
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
# A fresh child sources lib.sh, records one pass, and exits without report; the
# harness EXIT trap must turn that into a loud non-zero, because ok/no return 0 by
# design and nothing else stands between a lost report line and a false green.
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

# ...and a file that DOES report keeps its own verdict untouched.
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

# A failing file's non-zero verdict survives the EXIT trap too.
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

report
