#!/usr/bin/env bash
# The signal path's unit-testable pieces: start_radvd()'s pre-pid latch, on_hup()'s
# refusal to reload during a shutdown, its refusal to reload a config radvd would
# reject or cannot find, and the shutdown arm's two-branch report. The traps arm before the config validation, so a signal landing in that
# window is LATCHED and delivered to the freshly assigned pid; without that,
# `docker stop` during startup waits out its timeout and SIGKILLs while an early
# HUP is swallowed. THE ORACLE IS THE DELIVERY, NOT THE DEATH — the stubbed
# radvd's pre-exec bash can consume the latch TERM, so asserting "the child is
# gone" races (~1 false failure in 15 runs before this rewrite); the recording
# stub forwards to the real kill, and case 1 requires an empty record, so neither
# latch case is a tautology.
#
# A run may also show an intermittent bash `wait_for: No record of process <pid>`
# line on stderr (measured: 12 of 30 whole-suite runs, 0-2 lines each, suite still
# green). It comes from the stub subshell dying inside that same pre-exec window and
# unwinding through lib.sh's inherited EXIT trap, not from reap()'s `wait`; it is
# bash-only and cannot occur in the image's ash. Do not chase it: the only
# redirection that reaches the writer covers the fork, and it swallows
# start_radvd()'s own `failed to deliver TERM` error.
#
# Lint directives, each against a stated guarantee rather than an assumption:
#   SC2015 - `cond && ok || no` cannot mis-fire: lib.sh's ok/no/skip return 0.
#   SC2034 - CONF/reload/shutdown are INPUTS the extracted functions read.
#   SC2329 - the kill stub is invoked indirectly, by the function it shadows.
# shellcheck disable=SC2015,SC2034,SC2329
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

load_function start_radvd
load_function on_hup
load_function on_term
# The trap registrations themselves, not a function: the end pattern is deliberately
# '^trap on_term' rather than the whole line, so an edited signal list is reported by
# case 7's assertion instead of as a harness range error naming the wrong subject.
TRAPS=$(extract_range '^trap on_hup HUP$' '^trap on_term' "$WORK/traps.sh") || exit 1

# The stub: the function body backgrounds `radvd ... &`, so exec makes the
# subshell BE the sleeper, and $! names it. It records its argv first: the two
# flags that carry the app's whole log contract (`-m stderr`, which routes radvd's
# own diagnostics into `docker logs`, and `-d` with the validated level) are
# otherwise asserted by nothing, so either can be deleted with the corpus green.
radvd() {
  printf '%s\n' "$*" >>"$ARGV"
  exec sleep 20
}

CONF=/dev/null
# start_radvd passes RADVD_DEBUG_LEVEL to radvd's -d. In the boot path the value
# is assigned and validated at top level before this function is ever reached, so
# the extraction needs it supplied here for the same reason CONF is: under set -u
# an unbound one aborts the function before it backgrounds anything, which reads
# as a signal-latch failure rather than as the missing variable it is.
RADVD_DEBUG_LEVEL=0
SIGNALS="$WORK/signals"
ARGV="$WORK/argv"
LOG="$WORK/log"

# Record every signal the function sends, then forward it for real.
kill() {
  printf '%s\n' "$*" >>"$SIGNALS"
  command kill "$@"
}

signalled() {
  grep -Fq -- "-TERM $1" "$SIGNALS"
}

reap() {
  command kill -TERM "$1" 2>/dev/null
  wait "$1" 2>/dev/null
}

start() {
  : >"$SIGNALS"
  : >"$ARGV"
  radvd_pid=""
  start_radvd
}

# --- 1. control: no latched signal, nothing is delivered --------------------------
# This is what keeps the two latch cases honest twice over: a stub that dies on its
# own would fail the liveness half, and a function that signals unconditionally
# would fail the empty-record half.
shutdown=0 reload=0
start
sleep 0.2
[ -n "$radvd_pid" ] && [ ! -s "$SIGNALS" ] && command kill -0 "$radvd_pid" 2>/dev/null \
  && ok "with no latched signal nothing is delivered and the started child stays up" \
  || no "control" "radvd_pid='$radvd_pid', signals=[$(tr '\n' ' ' <"$SIGNALS")]"
grep -Fq -- '-m stderr' "$ARGV" && grep -Fq -- "-d $RADVD_DEBUG_LEVEL" "$ARGV" \
  && ok "the radvd invocation routes logs to stderr and passes the resolved debug level" \
  || no "radvd argv" "recorded: $(cat "$ARGV")"
reap "$radvd_pid"

# --- 2. a TERM latched before the pid existed is delivered to the fresh child -----
shutdown=1 reload=0
start
signalled "$radvd_pid" \
  && ok "a shutdown latched during validation is delivered as TERM to the freshly started child" \
  || no "shutdown latch" "no TERM recorded for $radvd_pid; signals=[$(tr '\n' ' ' <"$SIGNALS")]"
reap "$radvd_pid"

# --- 3. same for a HUP latched before the pid existed ------------------------------
shutdown=0 reload=1
start
signalled "$radvd_pid" \
  && ok "a reload latched during validation is delivered as TERM so the loop restarts it" \
  || no "reload latch" "no TERM recorded for $radvd_pid; signals=[$(tr '\n' ' ' <"$SIGNALS")]"
reap "$radvd_pid"

# --- 4. control: a HUP outside a shutdown does reload -----------------------------
# Without it, case 5 below would pass against an on_hup that ignores every HUP.
# The throwaway child stands in for radvd for the same reason the cases above use
# one: the recorder FORWARDS the signal, and radvd_pid=$$ would deliver the TERM to
# the process running this file, aborting it before report.
sleep 20 &
radvd_pid=$!
shutdown=0 reload=0
: >"$SIGNALS"
on_hup 2>"$LOG" 3>&2
[ "$reload" -eq 1 ] && signalled "$radvd_pid" \
  && grep -Fq 'msg="SIGHUP received; restarting radvd to reload config"' "$LOG" \
  && ok "a HUP outside a shutdown sets the reload flag and TERMs the daemon" \
  || no "hup control" "reload=$reload, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"
reap "$radvd_pid"

# --- 5. a HUP that lands DURING a shutdown is ignored -------------------------------
# Both handlers TERM the same child, so without the early return the late HUP sets
# reload=1 and the supervisor loop restarts the daemon on_term is stopping — the
# container comes back up out of a `docker stop`. Three assertions, none redundant:
# the early return (nothing signalled), the flag order (reload untouched), and the
# report (the operator sees why the reload did not happen).
sleep 20 &
radvd_pid=$!
shutdown=1 reload=0
: >"$SIGNALS"
on_hup 2>"$LOG" 3>&2
[ ! -s "$SIGNALS" ] && [ "$reload" -eq 0 ] \
  && grep -Fq 'msg="SIGHUP received during shutdown; reload ignored"' "$LOG" \
  && command kill -0 "$radvd_pid" 2>/dev/null \
  && ok "a HUP during shutdown is logged and ignored: no signal, no reload flag, child untouched" \
  || no "hup during shutdown" "reload=$reload, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"
reap "$radvd_pid"

# --- 6. a SIGHUP whose config check fails is REFUSED, and radvd keeps serving -----
# The reload stops radvd before its replacement reads the config, so accepting a
# bad edit costs the segment its RA emitter for nothing. Three arms, none
# redundant: the refusal (no flag, no signal, child untouched), the absent-config
# arm an ordinary editing accident takes (an editor's write-rename window, a mount
# hiccup) where there is no file for radvd to reject, and the control that a
# passing check still reloads — without which both refusals would pass against an
# on_hup that refuses every HUP.
HUPDIR=$(mktemp -d "$WORK/hup.XXXXXX")
mkdir "$HUPDIR/bin"
CONF="$HUPDIR/radvd.conf"
# on_hup runs `timeout 5 radvd -c`, so radvd has to be a real process here: the
# recording shell function above is invisible to timeout's exec.
stub_radvd() {
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "radvd stub: $*" >&2' "exit $1" >"$HUPDIR/bin/radvd"
  chmod +x "$HUPDIR/bin/radvd"
}
PATH="$HUPDIR/bin:$PATH"

printf 'interface eth0 { AdvSendAdvert on; };\n' >"$CONF"
stub_radvd 1
sleep 20 &
radvd_pid=$!
shutdown=0 reload=0
: >"$SIGNALS"
on_hup 2>"$LOG" 3>&2
[ "$reload" -eq 0 ] && [ ! -s "$SIGNALS" ] \
  && command kill -0 "$radvd_pid" 2>/dev/null \
  && grep -Fq 'msg="SIGHUP reload refused' "$LOG" \
  && ok "a HUP whose config check fails is refused: no reload flag, no signal, radvd untouched" \
  || no "refused reload" "reload=$reload, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"
reap "$radvd_pid"

rm -f "$CONF"
stub_radvd 0
sleep 20 &
radvd_pid=$!
shutdown=0 reload=0
: >"$SIGNALS"
on_hup 2>"$LOG" 3>&2
[ "$reload" -eq 0 ] && [ ! -s "$SIGNALS" ] \
  && command kill -0 "$radvd_pid" 2>/dev/null \
  && grep -Fq 'radvd.conf is absent' "$LOG" \
  && ok "a HUP with the config gone is refused too, where a config check has nothing to reject" \
  || no "absent-config reload" "reload=$reload, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"
reap "$radvd_pid"

printf 'interface eth0 { AdvSendAdvert on; };\n' >"$CONF"
stub_radvd 0
sleep 20 &
radvd_pid=$!
shutdown=0 reload=0
: >"$SIGNALS"
on_hup 2>"$LOG" 3>&2
[ "$reload" -eq 1 ] && signalled "$radvd_pid" \
  && ok "a HUP whose config check passes still sets the reload flag and TERMs the daemon" \
  || no "accepted reload" "reload=$reload, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"
reap "$radvd_pid"

# --- 7. the trap maps BOTH published shutdown signals to on_term --------------------
# CONTRIBUTING's "Design boundaries (please preserve)" promises SIGTERM/SIGINT and
# nothing else reads either side, so deleting INT is invisible to the whole corpus.
# Both sides are read at run time: the registration is executed, and the promise is
# pulled out of the bullet that makes it.
PROMISE=$(sed -n '/^- \*\*The entrypoint supervises radvd/,/^- \*\*/p' \
  "$REPO_ROOT/CONTRIBUTING.md")
registered=$(bash -c '
  set -u
  . "$1"
  . "$2"
  trap -p TERM INT
' _ "$WORK/on_term.sh" "$TRAPS" 2>/dev/null)
# The searched string is CONTRIBUTING's literal markdown, backticks included, so the
# single quotes are required: expansion here would run `/` as a command substitution.
# shellcheck disable=SC2016
[ "$(grep -c 'on_term' <<<"$registered")" -eq 2 ] \
  && grep -q 'SIGTERM`/`SIGINT`' <<<"$PROMISE" \
  && ok "both published shutdown signals are trapped to on_term, and CONTRIBUTING still promises both" \
  || no "shutdown signal contract" "registered: $(tr '\n' ' ' <<<"$registered"), promise found: $(grep -c 'SIGTERM`/`SIGINT`' <<<"$PROMISE")"

# --- 8. the shutdown arm reports a refused TERM as unconfirmable ------------------
# The arm lives inline in the supervisor loop, so it is extracted as a RANGE. The
# start anchor is the comment line, NOT `if [ "$shutdown" -eq 1 ]; then`: that
# spelling matches on_hup's guard at the top of the file too, and a sed range
# restarts, so it emitted both blocks concatenated — sourced with shutdown=1 the
# guard's `return` fired and the subject never ran (measured: byte-identical
# outcome against HEAD and against a collapsed arm, so it witnessed nothing).
# Nothing else reads signal_failed: both arms exit 0, every container scenario
# holds CAP_KILL, and README:173 publishes the refusal line, so without these
# cases the branch can invert with the whole corpus green.
ARM=$(extract_range '^    # Exit 0 either way' '^    exit 0$' "$WORK/shutdown_arm.sh") || exit 1
WARN='msg="the TERM could not be delivered to radvd; a graceful stop cannot be confirmed"'
INFO='msg="radvd stopped on shutdown signal (SIGTERM/SIGINT)"'

# The arm ends in `exit 0`, so it runs in a bounded child. signal_failed is its only
# input: the extraction begins AFTER the `[ "$shutdown" -eq 1 ]` test, so under set -u
# the flag has to be supplied the way CONF is above. stderr is redirected at the
# child's own invocation rather than around a brace group, which would swallow the
# lines this asserts on.
run_arm() {
  bash -c 'set -u; signal_failed=$1; . "$2"' _ "$1" "$ARM" 2>"$LOG"
}

run_arm 1
rc=$?
grep -Fq "$WARN" "$LOG" && ! grep -Fq "$INFO" "$LOG" && [ "$rc" -eq 0 ] \
  && ok "a refused TERM reports that a graceful stop cannot be confirmed, and still exits 0" \
  || no "refused-TERM report" "rc=$rc, log: $(tr '\n' '|' <"$LOG")"

# --- 9. control: a delivered TERM reports the graceful stop instead ----------------
# Without it, case 8 would pass against an arm that printed the warning
# unconditionally — the same collapse in the other direction.
run_arm 0
rc=$?
grep -Fq "$INFO" "$LOG" && ! grep -Fq "$WARN" "$LOG" && [ "$rc" -eq 0 ] \
  && ok "a delivered TERM reports the graceful stop, and exits 0" \
  || no "delivered-TERM report" "rc=$rc, log: $(tr '\n' '|' <"$LOG")"

# --- 10. the README still publishes the sentence the refusal arm prints ------------
# Same both-sides-at-run-time shape as case 7: the arm's text is a published
# operator-facing string, so an edit to either side alone is red.
grep -Fq 'a graceful stop cannot be confirmed' "$REPO_ROOT/README.md" \
  && ok "the README still publishes the refusal line the shutdown arm prints" \
  || no "published refusal line" "README.md no longer carries 'a graceful stop cannot be confirmed'"

report
