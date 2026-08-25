#!/usr/bin/env bash
# The RADVD_DEBUG_LEVEL gate: the inline default-and-validate block that decides
# radvd's -d verbosity, and a boot fatal.
#
# This is inline boot code, not a function, so it comes out via extract_range and
# runs in a subshell per case — `exit 1` must reach a process boundary here, not
# this file. sanitize_log_value is sourced alongside it because the refusal path
# delegates the echoed value to it.
#
# Why it earns a unit test rather than leaning on scripts/smoke.sh: the smoke test
# proves the fatal end to end, but it needs a built image and a docker daemon, and
# it can afford exactly one invalid value. The interesting cases are the ones a
# healthy container never reaches and a single container run cannot enumerate —
# every accepted level, the multi-digit rejection the one-character glob implies,
# and the two properties of the echoed value (sanitized, capped) that stop a
# malformed env var from forging the log line.
#
# Lint directives, each against a stated guarantee rather than an assumption:
#   SC2015 - the `cond && ok || no` form cannot mis-fire, because lib.sh's
#     ok/no/skip return 0 unconditionally by design (see their comments).
#   SC2016 - run_level's bash -c script is single-quoted BECAUSE nothing may
#     expand in this shell: $1/$2 are the subshell's own positionals.
# shellcheck disable=SC2015,SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The block runs from the defaulting assignment to the case that closes it.
GATE=$(extract_range '^RADVD_DEBUG_LEVEL=' '^esac$' "$WORK/gate.sh") || exit 1
SANITIZER=$(extract_function sanitize_log_value "$WORK/sanitize_log_value.sh") || exit 1

LOG="$WORK/log"

# Run the gate with RADVD_DEBUG_LEVEL set to $1, or with it UNSET when called with
# no argument, so the defaulting branch is reachable too.
run_level() {
  _rc=0
  if [ "$#" -eq 0 ]; then
    unset RADVD_DEBUG_LEVEL
  else
    export RADVD_DEBUG_LEVEL="$1"
  fi
  bash -c '
    set -u
    . "$1"
    . "$2"
    printf "resolved=%s\n" "$RADVD_DEBUG_LEVEL" >&2
  ' _ "$SANITIZER" "$GATE" 2>"$LOG" || _rc=$?
  unset RADVD_DEBUG_LEVEL
}

logged() {
  grep -Fq "$1" "$LOG"
}

# The README's RadvdConfigError alert rule is an exact-string contract between this
# fatal line and an operator's Loki rule, so read BOTH sides: pull the rule's own
# `|~` pattern out of the README and match the captured output against it as the
# regex Loki will use. Scoped to this one rule rather than grepping the file, because
# a file-wide match can pass against a pattern that has drifted onto another line; an
# empty extraction fails the assertion below rather than matching silently.
ALERT_RULE=$(sed -n '/alert: RadvdConfigError/,/^        for:/p' "$REPO_ROOT/README.md" \
  | sed -n 's/^[[:space:]]*|~ `\(.*\)` \[[0-9]\+[a-z]\]$/\1/p')

# --- 1. unset defaults to 0, the quiet level -------------------------------------
# The whole point of the change: a container nobody configured gets quiet logs.
run_level
[ "$_rc" -eq 0 ] && logged 'resolved=0' && ! logged 'level=error' \
  && ok "an unset RADVD_DEBUG_LEVEL defaults to 0" \
  || no "unset default" "rc=$_rc, log: $(cat "$LOG")"

# --- 2. every documented level is accepted verbatim -------------------------------
# The README promises 0-5; a gate that quietly rejected one of them would be a
# documentation lie no container test would catch.
for lvl in 0 1 2 3 4 5; do
  run_level "$lvl"
  [ "$_rc" -eq 0 ] && logged "resolved=$lvl" && ! logged 'level=error' \
    && ok "level $lvl is accepted and passed through unchanged" \
    || no "level $lvl accepted" "rc=$_rc, log: $(cat "$LOG")"
done

# --- 3. an EMPTY value defaults rather than failing -------------------------------
# `${RADVD_DEBUG_LEVEL:-0}` substitutes on empty as well as unset, so `-e
# RADVD_DEBUG_LEVEL=` is the quiet default and not an operator error. Pinned
# because the opposite reading is just as plausible from the code.
run_level ""
[ "$_rc" -eq 0 ] && logged 'resolved=0' && ! logged 'level=error' \
  && ok "an empty RADVD_DEBUG_LEVEL defaults to 0 rather than failing" \
  || no "empty defaults" "rc=$_rc, log: $(cat "$LOG")"

# --- 4. out-of-range and non-numeric values fail closed ---------------------------
# `10` is the case worth having: the gate is a one-character glob, so a
# multi-digit value is rejected no matter what its digits are. radvd's -d takes a
# single digit, so this is correct — but it is not self-evident, and a future
# widening to [0-9]* would silently start accepting 10 as "level 1, 0".
for bad in 6 9 10 42 x -1 "1 2"; do
  run_level "$bad"
  [ "$_rc" -eq 1 ] && logged 'msg="invalid RADVD_DEBUG_LEVEL' && ! logged 'resolved=' \
    && ok "'$bad' fails closed with exit 1 before radvd is reached" \
    || no "'$bad' rejected" "rc=$_rc, log: $(cat "$LOG")"
done

# --- 5. the echoed value cannot forge or break the log line -----------------------
# The refusal prints the offending value, which is attacker-supplied in the sense
# that matters here: whoever wrote the compose file. A quote would close the
# value= field early and a newline would start a second record, so both are
# neutralized to '?' before the printf sees them.
run_level '9"bogus'
[ "$_rc" -eq 1 ] && logged 'value="9?bogus"' \
  && ok "a quote in the value is neutralized to ? rather than closing the field" \
  || no "quote neutralized" "rc=$_rc, log: $(cat "$LOG")"
[ -n "$ALERT_RULE" ] && grep -Eq "$ALERT_RULE" "$LOG" \
  && ok "the invalid-level fatal line matches the README's RadvdConfigError alert pattern" \
  || no "alert contract (invalid level)" "rule='$ALERT_RULE', log: $(cat "$LOG")"

run_level '9
level=error msg="forged"'
[ "$_rc" -eq 1 ] && [ "$(grep -c 'level=error' "$LOG")" -eq 1 ] \
  && ok "an embedded newline cannot forge a second log record" \
  || no "newline joined" "rc=$_rc, lines=$(grep -c 'level=error' "$LOG"), log: $(cat "$LOG")"

run_level '9\bogus'
[ "$_rc" -eq 1 ] && logged 'value="9?bogus"' \
  && ok "a backslash in the value is neutralized to ?" \
  || no "backslash neutralized" "rc=$_rc, log: $(cat "$LOG")"

# The three classes a control-character pass cannot see, each arriving as a
# multi-byte sequence rather than as a C0 byte: C1 (U+0085 NEL), Bidi_Control
# (U+202E) and the line separator U+2028. runesafe's README is the fleet's written
# policy on what must not survive the trip to a log sink; this tier applies it with
# a printable-ASCII range map, so each byte of the sequence becomes one space.
run_level "$(printf '9\302\205bogus')"
[ "$_rc" -eq 1 ] && logged 'value="9  bogus"' \
  && ok "a C1 control (U+0085) is flattened instead of reaching the log sink" \
  || no "C1 neutralized" "rc=$_rc, log: $(cat "$LOG")"

run_level "$(printf '9\342\200\256bogus')"
[ "$_rc" -eq 1 ] && logged 'value="9   bogus"' \
  && ok "a Bidi_Control (U+202E) cannot reorder the rendered log line" \
  || no "Bidi_Control neutralized" "rc=$_rc, log: $(cat "$LOG")"

run_level "$(printf '9\342\200\250bogus')"
[ "$_rc" -eq 1 ] && logged 'value="9   bogus"' \
  && ok "U+2028 cannot split the record in a viewer that honours it as a terminator" \
  || no "U+2028 neutralized" "rc=$_rc, log: $(cat "$LOG")"

# --- 6. the echoed value is length-capped, and says when it was cut ----------------
# An env var has no useful length bound; the cap is what stops one typo from
# writing an unbounded line. 32 chars of payload, so the assertion is the cap and
# not the sanitizer. The marker is not decoration: without it a 32-character level
# an operator really typed is byte-identical to the head of a 200-character one.
run_level "$(printf 'A%.0s' $(seq 1 200))"
capped=$(sed -n 's/.*value="\([^"]*\)".*/\1/p' "$LOG")
payload=${capped%"[truncated]"}
[ "$_rc" -eq 1 ] && [ "${#payload}" -eq 32 ] && [ "$payload" != "$capped" ] \
  && ok "the echoed value is capped at 32 characters and marked as truncated" \
  || no "value capped" "rc=$_rc, value='$capped', log: $(cat "$LOG")"

report
