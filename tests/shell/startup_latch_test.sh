#!/usr/bin/env bash
# The signal path's two unit-testable pieces: start_radvd()'s pre-pid latch, and
# on_hup()'s refusal to reload during a shutdown.
#
# The entrypoint arms its HUP/TERM traps before the config validation so a signal
# landing in that window is not lost — but the handlers can only kill a child that
# exists, so they LATCH the flag and start_radvd delivers it to the freshly
# assigned pid. Remove that latch and `docker stop` during startup waits out its
# full timeout and SIGKILLs, and an early HUP is swallowed with no reload. No
# container test hits the validation window deterministically; this one sets the
# flags directly.
#
# THE ORACLE IS THE DELIVERY, NOT THE DEATH, and that is a correctness point rather
# than a convenience. Asserting "the child is gone" infers delivery from an outcome
# that a race can supply or withhold: `radvd` is stubbed as a shell function, so
# `radvd ... &` forks a bash that must still `exec`, and while ANY EXIT trap is set
# (this harness sets one) that pre-exec bash installs terminating-signal handlers.
# It CONSUMES the latch TERM into a deferred flag, and when the exec wins the race
# the flag dies with the bash image — the sleep starts with no pending signal and
# outlives the poll window. Measured before this rewrite: ~1 false failure per 15
# runs of this file. The contract is "the latched signal is delivered to the fresh
# pid", so the test records the delivery and forwards it, which no scheduling order
# can perturb.
#
# The recording stub is not a tautology: it FORWARDS to the real kill, and the
# control case below requires that NO signal was recorded. With the latch removed,
# nothing is recorded and both latch cases fail.
#
# Lint directives, each against a stated guarantee rather than an assumption:
#   SC2015 - the `cond && ok || no` form cannot mis-fire, because lib.sh's
#     ok/no/skip return 0 unconditionally by design (see their comments).
#   SC2034 - CONF/reload/shutdown are the INPUTS the extracted function reads at
#     runtime; shellcheck cannot see those reads.
#   SC2329 - the kill stub is invoked INDIRECTLY, by the extracted function it
#     shadows, which shellcheck cannot see.
# shellcheck disable=SC2015,SC2034,SC2329
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

load_function start_radvd
load_function on_hup

# The stub: the function body backgrounds `radvd ... &`, so exec makes the
# subshell BE the sleeper, and $! names it.
radvd() { exec sleep 20; }

CONF=/dev/null
# start_radvd passes RADVD_DEBUG_LEVEL to radvd's -d. In the boot path the value
# is assigned and validated at top level before this function is ever reached, so
# the extraction needs it supplied here for the same reason CONF is: under set -u
# an unbound one aborts the function before it backgrounds anything, which reads
# as a signal-latch failure rather than as the missing variable it is.
RADVD_DEBUG_LEVEL=0
SIGNALS="$WORK/signals"
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
on_hup 2>"$LOG"
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
on_hup 2>"$LOG"
[ ! -s "$SIGNALS" ] && [ "$reload" -eq 0 ] \
  && grep -Fq 'msg="SIGHUP received during shutdown; reload ignored"' "$LOG" \
  && command kill -0 "$radvd_pid" 2>/dev/null \
  && ok "a HUP during shutdown is logged and ignored: no signal, no reload flag, child untouched" \
  || no "hup during shutdown" "reload=$reload, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"
reap "$radvd_pid"

report
