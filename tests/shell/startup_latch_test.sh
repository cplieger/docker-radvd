#!/usr/bin/env bash
# A pre-pid shutdown must prevent a start.
# SC2015: lib.sh verdict helpers return 0. SC2034/SC2329: extracted child inputs.
# shellcheck disable=SC2015,SC2034,SC2329
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

load_function start_radvd
load_function on_hup
load_function on_term
# Keep the trap range anchored to the registered signals.
TRAPS=$(extract_range '^trap on_hup HUP$' '^trap on_term' "$WORK/traps.sh") || exit 1

# Record argv before replacing the child shell with the sleeper.
radvd() {
  printf '%s\n' "$*" >>"$ARGV"
  exec sleep 20
}

CONF=/dev/null
# Extracted start_radvd needs the top-level value under set -u.
RADVD_DEBUG_LEVEL=0
sig_seen=0
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
  start_radvd 2>"$LOG"
}

# --- 1. control: no latched signal, nothing is delivered --------------------------
# This is what keeps the two latch cases honest twice over: a stub that dies on its
# own would fail the liveness half, and a function that signals unconditionally
# would fail the empty-record half.
shutdown=0 reload=0
signal_failed=1
start
sleep 0.2
[ -n "$radvd_pid" ] && [ ! -s "$SIGNALS" ] && command kill -0 "$radvd_pid" 2>/dev/null \
  && ok "with no latched signal nothing is delivered and the started child stays up" \
  || no "control" "radvd_pid='$radvd_pid', signals=[$(tr '\n' ' ' <"$SIGNALS")]"
grep -Fq -- '--logmethod=stderr' "$ARGV" && grep -Fq -- "--debug=$RADVD_DEBUG_LEVEL" "$ARGV" \
  && ok "the radvd invocation routes logs to stderr and passes the resolved debug level" \
  || no "radvd argv" "recorded: $(cat "$ARGV")"
grep -Fq 'msg="starting radvd"' "$LOG" \
  && ok "the un-gated path logs the start" \
  || no "start log line" "log: $(cat "$LOG")"
[ "$signal_failed" -eq 0 ] \
  && ok "starting a child clears a prior generation's delivery refusal" \
  || no "delivery-refusal scope" "signal_failed=$signal_failed after start_radvd"
reap "$radvd_pid"

shutdown=1 reload=0
: >"$SIGNALS"
: >"$ARGV"
radvd_pid=""
(start_radvd) 2>"$LOG"
rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$ARGV" ] && [ ! -s "$SIGNALS" ] \
  && grep -Fq 'msg="shutdown signal received before radvd started; exiting without starting it"' "$LOG" \
  && ! grep -Fq 'msg="starting radvd"' "$LOG" \
  && ok "a shutdown latched while no child existed refuses the start: exit 0, no fork, no delivery" \
  || no "shutdown gate" "rc=$rc, argv=[$(tr '\n' ' ' <"$ARGV")], signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"

# Extract the post-fork shutdown block by its stable source anchors.
RESIDUE=$(extract_range '^  # A TERM landing between the gate' '^  fi$' "$WORK/residue.sh") || exit 1
out=$(bash -c '
  set -u
  shutdown=1
  signal_failed=0
  sleep 3 &
  radvd_pid=$!
  . "$1"
  wait "$radvd_pid"
  printf "signal_failed=%s wait_rc=%s\n" "$signal_failed" "$?"
' _ "$RESIDUE" 2>"$LOG")
[ "$out" = "signal_failed=0 wait_rc=143" ] && ! grep -Fq 'failed to deliver TERM' "$LOG" \
  && ok "a shutdown latched after the gate is still delivered to the fresh pid" \
  || no "residue delivery" "out: $out, log: $(cat "$LOG")"

# A refused post-fork TERM must set signal_failed for the supervisor.
out=$(bash -c '
  set -u
  shutdown=1
  signal_failed=0
  sleep 0.1 &
  radvd_pid=$!
  wait "$radvd_pid"
  . "$1"
  printf "signal_failed=%s\n" "$signal_failed"
' _ "$RESIDUE" 2>"$LOG")
[ "$out" = "signal_failed=1" ] \
  && grep -Fq 'msg="failed to deliver TERM to radvd; the container may lack CAP_KILL, or the child was already reaped"' "$LOG" \
  && ok "a refused residue delivery arms signal_failed and reports it" \
  || no "residue refusal" "out: $out, log: $(cat "$LOG")"

# --- 3. a latched reload is NOT an operand of the shutdown gate -------------------
# `reload` is armed only after a confirmed TERM to an assigned pid, so it cannot
# describe a no-child state: a reload must neither refuse the start nor deliver
# anything to the fresh child.
shutdown=0 reload=1
start
sleep 0.2
[ -n "$radvd_pid" ] && [ ! -s "$SIGNALS" ] && command kill -0 "$radvd_pid" 2>/dev/null \
  && ok "a latched reload neither gates the start nor delivers to the fresh child" \
  || no "reload latch" "radvd_pid='$radvd_pid', signals=[$(tr '\n' ' ' <"$SIGNALS")]"
reap "$radvd_pid"

# on_hup refuses any config that is not a regular file and config-tests the rest, so
# every case from here down needs a real regular-file config and a real `radvd` on
# PATH: `timeout 5 radvd --configtest` execs, and the recording shell function above is
# invisible to that exec.
HUPDIR=$(mktemp -d "$WORK/hup.XXXXXX")
mkdir "$HUPDIR/bin"
CONF="$HUPDIR/radvd.conf"
stub_radvd() {
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "radvd stub: $*" >&2' "exit $1" >"$HUPDIR/bin/radvd"
  chmod +x "$HUPDIR/bin/radvd"
}
PATH="$HUPDIR/bin:$PATH"
printf 'interface eth0 { AdvSendAdvert on; };\n' >"$CONF"
stub_radvd 0
# Asserted before it is relied on: a missing fixture produces the same refusal as a
# correctly refusing on_hup, which would turn the control below green for the wrong
# reason and take case 5 with it.
[ -f "$CONF" ] && [ -x "$HUPDIR/bin/radvd" ] \
  && ok "the reload cases have a regular-file config and a radvd stub on PATH" \
  || no "hup fixture" "CONF=$CONF, stub=$HUPDIR/bin/radvd"

# --- signal handlers with no child assigned --------------------------------------
radvd_pid=""
shutdown=0 reload=0 signal_failed=0 sig_seen=0
: >"$SIGNALS"
on_term 2>"$LOG"
[ "$shutdown" -eq 1 ] && [ "$signal_failed" -eq 0 ] && [ "$sig_seen" -eq 1 ] && [ ! -s "$SIGNALS" ] \
  && grep -Fq 'msg="shutdown signal received; stopping radvd"' "$LOG" \
  && ! grep -Fq 'failed to deliver TERM to radvd' "$LOG" \
  && ok "TERM with no assigned child latches shutdown without reporting a delivery failure" \
  || no "empty-pid TERM" "shutdown=$shutdown, signal_failed=$signal_failed, sig_seen=$sig_seen, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"

# A HUP with nothing to signal cannot observe a delivery, so it is REFUSED rather
# than latched: radvd has not read the config yet, and arming the reload flag would
# promise the loop an exit that is never coming. The trap entry is still recorded.
radvd_pid=""
shutdown=0 reload=0 signal_failed=0 sig_seen=0
: >"$SIGNALS"
on_hup 2>"$LOG"
[ "$reload" -eq 0 ] && [ "$signal_failed" -eq 0 ] && [ "$sig_seen" -eq 1 ] && [ ! -s "$SIGNALS" ] \
  && grep -Fq 'msg="SIGHUP reload refused: TERM delivery to radvd could not be confirmed' "$LOG" \
  && ok "HUP with no assigned child is refused, not latched, and still records the trap entry" \
  || no "empty-pid HUP" "reload=$reload, signal_failed=$signal_failed, sig_seen=$sig_seen, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"

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

# --- 6. a SIGHUP whose config check fails is REFUSED, and radvd keeps serving -----
# The reload stops radvd before its replacement reads the config, so accepting a
# bad edit costs the segment its RA emitter for nothing. Two arms, none
# redundant: the refusal (no flag, no signal, child untouched), and the
# absent-config arm an ordinary editing accident takes (an editor's write-rename
# window, a mount hiccup) where there is no file for radvd to reject. Case 4 is
# the control that keeps both honest against an on_hup that refuses every HUP;
# recovery after a refusal — the operator fixes the config and reloads again — is
# pinned against a real container by scripts/smoke.sh's malformed-reload scenario.
printf 'interface eth0 { AdvSendAdvert on; };\n' >"$CONF"
stub_radvd 1
sleep 20 &
radvd_pid=$!
shutdown=0 reload=0 sig_seen=0
: >"$SIGNALS"
on_hup 2>"$LOG"
[ "$reload" -eq 0 ] && [ ! -s "$SIGNALS" ] && [ "$sig_seen" -eq 1 ] \
  && command kill -0 "$radvd_pid" 2>/dev/null \
  && grep -Fq 'msg="SIGHUP reload refused: radvd rejected the mounted config"' "$LOG" \
  && grep -Eq 'radvd stub: --configtest --config=.* --username=radvd( |$)' "$LOG" \
  && ok "a HUP whose config check fails is refused: no reload flag, no signal, radvd untouched" \
  || no "refused reload" "reload=$reload, sig_seen=$sig_seen, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"
reap "$radvd_pid"

# The same refusal for an elapsed config-check budget, which is a DIFFERENT
# disposition: the operator is told the check did not finish, and radvd's captured
# output is not republished because a killed check has no verdict to report. Both
# statuses are driven because the two timeouts disagree — GNU coreutils translates an
# elapsed budget to 124 while BusyBox, the shipped one, reports the watchdog's signal
# as 143 — so classifying only 124 leaves the shipped image on the rejection arm.
for hup_timeout_rc in 124 143; do
  stub_radvd "$hup_timeout_rc"
  sleep 20 &
  radvd_pid=$!
  shutdown=0 reload=0 sig_seen=0
  : >"$SIGNALS"
  on_hup 2>"$LOG"
  [ "$reload" -eq 0 ] && [ ! -s "$SIGNALS" ] && [ "$sig_seen" -eq 1 ] \
    && command kill -0 "$radvd_pid" 2>/dev/null \
    && grep -Fq 'msg="SIGHUP reload refused: the config check did not finish within 5s"' "$LOG" \
    && ! grep -Fq 'radvd stub: --configtest ' "$LOG" \
    && ok "a config check exiting $hup_timeout_rc is refused as a timeout, with no captured output republished" \
    || no "timeout reload rc=$hup_timeout_rc" "reload=$reload, sig_seen=$sig_seen, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"
  reap "$radvd_pid"
done

rm -f "$CONF"
stub_radvd 0
sleep 20 &
radvd_pid=$!
shutdown=0 reload=0 sig_seen=0
: >"$SIGNALS"
on_hup 2>"$LOG"
[ "$reload" -eq 0 ] && [ ! -s "$SIGNALS" ] \
  && command kill -0 "$radvd_pid" 2>/dev/null \
  && grep -Fq 'radvd.conf is absent' "$LOG" \
  && ok "a HUP with the config gone is refused too, where a config check has nothing to reject" \
  || no "absent-config reload" "reload=$reload, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"
reap "$radvd_pid"

# --- an insecure-permission warning is fatal only at debug level 0 ---------------
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "Insecure file permissions on config" >&2' \
  'exit 0' >"$HUPDIR/bin/radvd"
chmod +x "$HUPDIR/bin/radvd"
printf 'interface eth0 { AdvSendAdvert on; };\n' >"$CONF"

RADVD_DEBUG_LEVEL=0
sleep 20 &
radvd_pid=$!
shutdown=0 reload=0 sig_seen=0
: >"$SIGNALS"
on_hup 2>"$LOG"
[ "$reload" -eq 0 ] && [ ! -s "$SIGNALS" ] \
  && command kill -0 "$radvd_pid" 2>/dev/null \
  && grep -Fq 'reports the config file permissions insecure' "$LOG" \
  && grep -Fq 'Insecure file permissions on config' "$LOG" \
  && ok "at debug level 0 an insecure-permission warning refuses reload and is republished" \
  || no "insecure permissions at level 0" "reload=$reload, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"
reap "$radvd_pid"

RADVD_DEBUG_LEVEL=1
sleep 20 &
radvd_pid=$!
shutdown=0 reload=0 sig_seen=0
: >"$SIGNALS"
on_hup 2>"$LOG"
[ "$reload" -eq 1 ] && signalled "$radvd_pid" \
  && ! grep -Fq 'SIGHUP reload refused' "$LOG" \
  && ok "at debug level 1 the same warning follows radvd's warn-and-continue path" \
  || no "insecure permissions at level 1" "reload=$reload, signals=[$(tr '\n' ' ' <"$SIGNALS")], log: $(cat "$LOG")"
reap "$radvd_pid"
RADVD_DEBUG_LEVEL=0

# --- 7. the trap maps BOTH published shutdown signals to on_term --------------------
# CONTRIBUTING's "Design boundaries (please preserve)" promises SIGTERM/SIGINT and
# nothing else reads either side, so deleting INT is invisible to the whole corpus.
# All three reads happen at run time: the TERM registration is executed, the INT one
# is read from the extracted trap line, and the promise is pulled out of the bullet
# that makes it.
# A signal ignored on entry to a non-interactive shell cannot be trapped (POSIX
# `trap`), so under an asynchronous launcher a child oracle for INT reports 1
# while entrypoint.sh's trap line is unchanged. TERM is never ignored on entry,
# so it stays an executed registration. The TRAPS extraction above is what makes
# the signal list assertable as text — see its own comment.
PROMISE=$(sed -n '/^- \*\*The entrypoint supervises radvd/,/^- \*\*/p' \
  "$REPO_ROOT/CONTRIBUTING.md")
registered=$(bash -c '
  set -u
  . "$1"
  . "$2"
  trap -p TERM
' _ "$WORK/on_term.sh" "$TRAPS" 2>/dev/null)
# The searched string is CONTRIBUTING's literal markdown, backticks included, so the
# single quotes are required: expansion here would run `/` as a command substitution.
# shellcheck disable=SC2016
[ "$(grep -c 'on_term' <<<"$registered")" -eq 1 ] \
  && grep -q '^trap on_term TERM INT$' "$TRAPS" \
  && grep -q 'SIGTERM`/`SIGINT`' <<<"$PROMISE" \
  && ok "both published shutdown signals are trapped to on_term, and CONTRIBUTING still promises both" \
  || no "shutdown signal contract" "registered: $(tr '\n' ' ' <<<"$registered"), signal list: $(grep -c '^trap on_term TERM INT$' "$TRAPS"), promise found: $(grep -c 'SIGTERM`/`SIGINT`' <<<"$PROMISE")"

# --- 8. the shutdown arm reports a refused TERM as unconfirmable ------------------
# The arm lives inline in the supervisor loop, so it is extracted as a RANGE anchored
# on this comment line: `if [ "$shutdown" -eq 1 ]; then` also matches on_hup's guard
# and a sed range restarts, so that spelling emits both blocks and the subject never
# runs. Nothing else reads signal_failed and both arms exit 0, so an inverted branch
# changes only which line is logged; scripts/smoke.sh scenario 10 is the
# container-level witness (hardened profile minus KILL) and these cases pin the arm
# without a container.
ARM=$(extract_range '^      # Exit 0 either way' '^      exit 0$' "$WORK/shutdown_arm.sh") || exit 1
WARN='msg="the TERM could not be delivered to radvd; a graceful stop cannot be confirmed"'
INFO='msg="radvd stopped on shutdown signal (SIGTERM/SIGINT)"'

# The arm ends in `exit 0`, so it runs in a bounded child. signal_failed and radvd_pid
# are its inputs: the extraction begins AFTER the `[ "$shutdown" -eq 1 ]` test, so under
# set -u both have to be supplied the way CONF is above, and the delivered arm reaps the
# child before it reports. stderr is redirected at the child's own invocation rather
# than around a brace group, which would swallow the lines this asserts on.
run_arm() {
  bash -c 'set -u; signal_failed=$1; sleep 0.2 & radvd_pid=$!; . "$2"' _ "$1" "$ARM" 2>"$LOG"
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

# --- 11. a latched shutdown whose TERM was refused does not wait for the child -----
# The skip lives inline in the loop, so it is extracted as a self-balanced RANGE. The
# `&&` is what makes the start anchor unique: `if [ "$shutdown" -eq 1 ]` alone also
# matches on_hup's guard and the arm below, and a sed range that restarts emits both
# blocks. The block's own `fi` is the first at that indent, and it holds no nested `if`.
# Its whole content is a control-flow decision, so the oracle is whether the block
# returns while a live child is still running.
# The anchors are the entrypoint's own literal text, `$` included, so the single quotes
# are required exactly as case 7's are.
# shellcheck disable=SC2016
SKIP=$(extract_range '^  if \[ "\$shutdown" -eq 1 \] && \[ "\$signal_failed" -eq 1 \]' \
  '^  fi$' "$WORK/wait_skip.sh") || exit 1
# Bounded, so a reverted skip fails this case instead of hanging the file; the child
# outlives the bound on purpose. BusyBox `timeout` reports 143 where GNU reports 124
# (shell.md), so the blocking arm asserts only "non-zero".
# The inner script is the CHILD shell's, so its `$1`/`$2`/`$status` must not expand
# here. shellcheck reads a `bash -c` string as a nested script only when `bash` is the
# command word, and the bound in front of it is not optional — case 8 needs no
# directive for the same construct because it has no `timeout`.
# shellcheck disable=SC2016
run_skip() {
  timeout 3 bash -c '
    set -u
    shutdown=$1
    signal_failed=$2
    sleep 5 &
    radvd_pid=$!
    . "$3"
    printf "status=%s\n" "$status"
    command kill -TERM "$radvd_pid" 2>/dev/null || true
  ' _ "$1" "$2" "$SKIP"
}

out=$(run_skip 1 1)
rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "status=0" ] \
  && ok "a shutdown latched before the loop whose TERM was refused does not wait for the child" \
  || no "latched refused shutdown skips the wait" "rc=$rc, out: $out"

# --- 12. control: a delivered shutdown still waits for the child -------------------
# Without it, case 11 would pass against a block that skipped the wait
# unconditionally — the same collapse case 9 exists to prevent one arm below.
out=$(run_skip 1 0)
rc=$?
[ "$rc" -ne 0 ] \
  && ok "with the TERM delivered the loop still waits for the child's own exit" \
  || no "delivered shutdown still waits" "rc=$rc, out: $out"

report
