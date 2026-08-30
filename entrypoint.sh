#!/bin/sh
# Supervises radvd rather than exec'ing it, so SIGHUP re-reads the config as root:
# CONTRIBUTING.md, "Design boundaries (please preserve)".
set -u

CONF="/etc/radvd/radvd.conf"

# Both tr stages replace 1:1 rather than delete: deletion shifts offsets and can
# splice two fragments into one token of the bad= list. \040-\176 stands in for
# [:print:], which BusyBox tr (v1.37.0) lacks, and LC_ALL=C makes the covered set
# a property of the code. Every survivor is single-byte ASCII, so the cap below
# cannot split a rune.
sanitize_log_value() {
  # shellcheck disable=SC1003 # not an escape attempt: tr maps `"` and `\` to literal `?` (verified on BusyBox v1.37.0)
  _clean=$(printf '%s' "$1" | tr '"\\' '??' | LC_ALL=C tr -c '\040-\176' ' ')
  _capped=$(printf '%s' "$_clean" | cut -c1-"$2")
  if [ "${#_clean}" -gt "${#_capped}" ]; then
    printf '%s[truncated]' "$_capped"
  else
    printf '%s' "$_capped"
  fi
}

# Resolved and validated before the traps below, because on_hup reads it: a handler
# that expands an unset name under `set -u` exits 2, and for PID 1 that is the
# container.
RADVD_DEBUG_LEVEL="${RADVD_DEBUG_LEVEL:-0}"
case "$RADVD_DEBUG_LEVEL" in
  [0-5]) ;;
  *)
    bad_level=$(sanitize_log_value "$RADVD_DEBUG_LEVEL" 32)
    printf 'level=error msg="invalid RADVD_DEBUG_LEVEL; expected an integer 0-5" value="%s"\n' "$bad_level" >&2
    exit 1
    ;;
esac

# Armed before preflight because PID 1 receives no default-disposition signal: a
# TERM during validation is latched here for start_radvd's shutdown gate.
radvd_pid=""
reload=0
shutdown=0
# Set when a TERM to the child was refused, so the shutdown arm cannot claim a
# graceful stop it never observed. Scoped to one child: start_radvd clears it.
signal_failed=0
# Set by both handlers so the loop can tell a trap-interrupted wait from a real
# radvd exit. A status above 128 cannot: a SIGKILLed radvd exits 137 too.
sig_seen=0
on_hup() {
  sig_seen=1
  if [ "$shutdown" -eq 1 ]; then
    printf 'level=info msg="SIGHUP received during shutdown; reload ignored"\n' >&2
    return
  fi
  # The reload stops radvd before its replacement reads the config, so a bad or
  # absent config here would leave the container with no daemon: refuse and keep
  # serving the last good one. `radvd -c` rejects nothing the daemon accepts, but it
  # runs radvd's config PARSER and stops there, so everything radvd validates after
  # parsing passes this gate: a filter, not a guarantee.
  if ! [ -f "$CONF" ]; then
    printf 'level=error msg="SIGHUP reload refused: radvd.conf is absent or not a regular file" path="%s"\n' "$CONF" >&2
    return
  fi
  hup_rc=0
  hup_ct=$(timeout 5 radvd --configtest --config="$CONF" --username=radvd 2>&1) || hup_rc=$?
  if [ "$hup_rc" -ne 0 ]; then
    # Neither timeout call site passes -k, so an elapsed budget is 124 (GNU) or
    # 143 (BusyBox, the shipped one) and 137 is unreachable at both.
    if [ "$hup_rc" -eq 124 ] || [ "$hup_rc" -eq 143 ]; then
      printf 'level=error msg="SIGHUP reload refused: the config check did not finish within 5s" path="%s"\n' "$CONF" >&2
    else
      printf 'level=error msg="SIGHUP reload refused: radvd rejected the mounted config" path="%s"\n' "$CONF" >&2
      # radvd's own text, verbatim and unstructured on purpose: README's
      # RadvdConfigError rule matches these bytes and scripts/smoke.sh asserts it.
      printf '%s\n' "$hup_ct" >&2
    fi
    return
  fi
  # `radvd -c` forces debuglevel 1 (radvd.c:289-290), which turns the conf_file
  # permission refusal into a warning it exits 0 on (radvd.c:319-325); the daemon at
  # debuglevel 0 exits 1 on the same file. At level 1 and above the daemon takes the
  # same warn arm, so refusing there would refuse a reload that would have worked.
  if [ "$RADVD_DEBUG_LEVEL" -eq 0 ] \
    && printf '%s\n' "$hup_ct" | grep -q 'Insecure file permissions'; then
    printf 'level=error msg="SIGHUP reload refused: radvd reports the config file permissions insecure and would exit at debug level 0" path="%s"\n' "$CONF" >&2
    printf '%s\n' "$hup_ct" >&2
    return
  fi
  # reload=1 promises the loop that an exit is coming, so only an observed
  # delivery may arm it.
  if [ -n "$radvd_pid" ] && kill -TERM "$radvd_pid" 2>/dev/null; then
    reload=1
    printf 'level=info msg="SIGHUP received; restarting radvd to reload config"\n' >&2
  else
    printf 'level=error msg="SIGHUP reload refused: TERM delivery to radvd could not be confirmed; radvd may not be running yet, the child may already have been reaped, or the container may lack CAP_KILL" pid="%s"\n' "$radvd_pid" >&2
  fi
}
on_term() {
  sig_seen=1
  shutdown=1
  printf 'level=info msg="shutdown signal received; stopping radvd"\n' >&2
  if [ -n "$radvd_pid" ] && ! kill -TERM "$radvd_pid" 2>/dev/null; then
    signal_failed=1
    printf 'level=error msg="failed to deliver TERM to radvd; the container may lack CAP_KILL, or the child was already reaped" pid="%s"\n' "$radvd_pid" >&2
  fi
}
trap on_hup HUP
trap on_term TERM INT

# Warn-only except the non-regular-node refusal below, which exits 1 from both call
# sites: no warning here is worth refusing the container over, and a single-node
# operator legitimately deploys without HA. Why HA needs its directives:
# CONTRIBUTING.md, "Design boundaries (please preserve)".
check_config_directives() {
  # A FIFO with no writer blocks in open/read and a device node may return EOF
  # immediately (/dev/null does), so neither gives the bounded regular-file
  # snapshot this scan needs. No POSIX-sh operation can type-check and open a node
  # atomically, so the bounded read below is the backstop; one read serves every gate.
  warn_scan_degraded() {
    scan_err=$(sanitize_log_value "$1" 200)
    printf 'level=warn msg="unable to scan mounted radvd config; directive validation is incomplete" err="%s" path="%s"\n' "$scan_err" "$CONF" >&2
  }
  if [ -e "$CONF" ] && ! [ -f "$CONF" ]; then
    printf 'level=error msg="radvd.conf is not a regular file" path="%s"\n' "$CONF" >&2
    exit 1
  fi
  # 5s: above any legitimate read of this config, below `docker stop`'s 10s grace.
  conf_snapshot=$({ timeout 5 cat "$CONF"; } 2>/dev/null)
  read_rc=$?
  if [ "$read_rc" -ne 0 ]; then
    if [ "$read_rc" -eq 124 ] || [ "$read_rc" -eq 143 ]; then
      warn_scan_degraded "read of the config exceeded 5s; the node may be a FIFO or a stalled mount"
    else
      # Content and cause must not share a stream: cat writes its output before
      # its error, so a merged read puts config bytes in the field naming the
      # cause. Bounded because this arm also runs on the reload path, where an
      # unbounded read wedges PID 1. The brace groups catch ash's job-status word.
      scan_cause=$({ timeout 5 cat "$CONF" 2>&1 >/dev/null; } 2>/dev/null)
      warn_scan_degraded "${scan_cause:-the re-read reported no diagnostic either}"
    fi
    return 0
  fi
  # radvd's scanner (v2.21 scanner.l:39) makes a double-quoted string ONE token and
  # the quotes are part of the value: its name for `interface "eth0"` is the 6-byte
  # `"eth0"`, and `"AdvRASrcAddress"` is a STRING, never the directive. So a naive
  # strip from the first `#` erases the `;` after `AdvCaptivePortalAPI "…/#/login"`.
  # This stage re-emits the quotes around the run and masks every byte meaningful to
  # the walk below (`{`, `}`, `;`, whitespace, the record separator) with `@`
  # inside it, so a quoted value decides nothing and reaches iface= masked.
  # Split on the quote, not byte by byte: a char loop is seconds on a large config.
  conf_scan=$(printf '%s\n' "$conf_snapshot" | awk '
    {
      # radvd scanner.l:39 makes a string backslash-escape aware, so an ODD
      # number of \" inside a value would invert a naive quote split. It runs
      # before the split, so its `@@` also reaches iface=: widening it widens
      # what the operator is told the interface is called (CONTRIBUTING).
      gsub(/\\./, "@@")
      n = split($0, seg, "\"")
      out = ""
      for (i = 1; i <= n; i++) {
        s = seg[i]
        if (instr) {
          gsub(/[{}; \t]/, "@", s)
          out = out s
        } else {
          # Only outside a quoted run: scanner.l:39 counts a CR inside a STRING
          # as part of the value, so deleting it there misspells the name.
          gsub(/\r/, "", s)
          # The bare string class at scanner.l:39 includes `#`, so the comment
          # rule at scanner.l:42 wins the longest match only at a token
          # boundary: `eth0#x` is one STRING token, not a name plus a comment.
          if (match(s, /(^|[{}; \t])#/)) {
            out = out substr(s, 1, RSTART + RLENGTH - 2)
            break
          }
          out = out s
        }
        if (i < n) {
          # Re-emit the delimiter, padded so the quoted run is its own token: the
          # quotes ARE part of the STRING value radvd reads, and a token carrying
          # them can never equal a directive keyword. scanner.l:39 puts an optional
          # `L` INSIDE that same token (`L?\"…\"`, either case because scanner.l:16
          # sets `caseless`), so no boundary may go there; the boundary class is what
          # still pads `ethL"0"`, which radvd itself lexes as two tokens.
          if (instr) { out = out "\" " } else { out = out (s ~ /(^|[{}; \t])[Ll]$/ ? "\"" : " \"") }
          instr = !instr
        }
      }
      # scanner.l:39 negates only the quote, so the string spans newlines too: while
      # it is open the record separator is one more byte of it, not a token boundary.
      if (instr) { printf "%s@", out } else { print out }
    }
  ')
  # Braces and `;` are padded into their own tokens, so a directive name counts only
  # on a statement boundary and `AdvRASrcAddress{fe80::1;}` needs no special case. A
  # directive is credited to the block it sits DIRECTLY inside, which is why depth is
  # compared rather than merely non-zero.
  # NO LINE OF THIS AWK PROGRAM MAY CLOSE IN COLUMN 0: tests/shell/lib.sh's
  # extract_function ends on /^[)}][[:space:]]*$/ and tests/smoke.sh's sed range
  # on /^}$/, so a column-0 closer silently truncates this function's extraction.
  printf '%s\n' "$conf_scan" | awk '
    function reset() {
      iface = ""
      entered = 0
      want_name = 0
      f_send = 0
      srcdepth = 0
      pend = ""
      bad = ""
    }
    function flush() {
      if (entered) {
        if (!f_send) { print "no_sendadvert " iface }
        if (bad != "") { print "bad_src " iface " " bad }
      }
      reset()
    }
    {
      line = $0
      gsub(/[{]/, " { ", line)
      gsub(/[}]/, " } ", line)
      gsub(/[;]/, " ; ", line)
      n = split(line, tok, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t == "") { continue }
        lt = tolower(t)
        if (t == "{") {
          depth++
          if (pend == "advrasrcaddress" && depth == 2) { srcdepth = depth }
          if (iface != "" && depth == 1) { entered = 1 }
          want_name = 0
          pend = ""
          continue
        }
        if (t == "}") {
          if (srcdepth != 0 && depth == srcdepth) { srcdepth = 0 }
          depth--
          want_name = 0
          pend = ""
          if (depth <= 0) {
            depth = 0
            flush()
          }
          continue
        }
        if (t == ";") {
          pend = ""
          continue
        }
        if (srcdepth != 0) {
          if (lt !~ /^fe[89ab][0-9a-f]:/) { bad = bad (bad ? ", " : "") lt }
          continue
        }
        if (want_name) {
          iface = t
          want_name = 0
          continue
        }
        if (depth == 0) {
          if (lt == "interface") { want_name = 1 }
          pend = ""
          continue
        }
        if (depth != 1) {
          pend = ""
          continue
        }
        if (pend == "advsendadvert") {
          f_send = (lt == "on")
          pend = ""
          continue
        }
        if (lt == "advsendadvert" || lt == "advrasrcaddress") {
          pend = lt
          continue
        }
        pend = ""
      }
    }
    END {
      flush()
    }
  ' | while read -r kind iface_name bad_addrs; do
    # iface= carries operator-supplied config text (upstream's scanner accepts
    # quoted, backslash-escaped STRING tokens), so it crosses bad='s trust boundary.
    case "$kind" in
      no_sendadvert)
        printf 'level=warn msg="no enabled AdvSendAdvert on directive found; radvd defaults it to off, so it will run and emit no router advertisements" iface="%s" path="%s"\n' "$(sanitize_log_value "$iface_name" 200)" "$CONF" >&2
        ;;
      bad_src)
        printf 'level=warn msg="AdvRASrcAddress is set to a non-link-local address; RFC 4861 requires an RA source to be link-local (fe80::/10), so hosts will silently discard these RAs" bad="%s" iface="%s" path="%s"\n' "$(sanitize_log_value "$bad_addrs" 200)" "$(sanitize_log_value "$iface_name" 200)" "$CONF" >&2
        ;;
    esac
  done
}

if [ -r "$CONF" ]; then
  check_config_directives
elif [ -e "$CONF" ]; then
  printf 'level=error msg="radvd.conf exists but is not readable" path="%s"\n' "$CONF" >&2
  exit 1
else
  printf 'level=warn msg="radvd.conf not found; radvd will fail to start" path="%s"\n' "$CONF" >&2
fi

# radvd refuses to start without the directory holding its --with-pidfile path.
if ! mkdir -p /run/radvd; then
  printf 'level=error msg="failed to create radvd PID directory; radvd cannot start" path="%s"\n' "/run/radvd" >&2
  exit 1
fi

start_radvd() {
  signal_failed=0
  # A shutdown latched while no radvd existed (preflight, or the reload gap
  # between reaping one generation and starting the next) is a stop that arrived
  # first. Starting radvd just to signal it races its own handler installation:
  # a lost race swallows the TERM and leaves PID 1 in `wait` until the stop
  # grace expires in SIGKILL — measured at 29-59% per hit under CPU contention.
  # The stop wins instead.
  if [ "$shutdown" -eq 1 ]; then
    printf 'level=info msg="shutdown signal received before radvd started; exiting without starting it"\n' >&2
    exit 0
  fi
  printf 'level=info msg="starting radvd" config="%s" debug_level="%s"\n' "$CONF" "$RADVD_DEBUG_LEVEL" >&2
  radvd --config="$CONF" --nodaemon --logmethod=stderr --debug="$RADVD_DEBUG_LEVEL" --username=radvd &
  radvd_pid=$!
  # A TERM landing between the gate above and the assignment just made latched
  # without a kill. That slice is microseconds against the ~250ms preflight the
  # gate closed, and this delivery still races radvd's handler installation;
  # the runtime's kill-after-grace is the backstop when it loses.
  if [ "$shutdown" -eq 1 ]; then
    if ! kill -TERM "$radvd_pid" 2>/dev/null; then
      signal_failed=1
      printf 'level=error msg="failed to deliver TERM to radvd; the container may lack CAP_KILL, or the child was already reaped" pid="%s"\n' "$radvd_pid" >&2
    fi
  fi
}

start_radvd

while :; do
  # A shutdown latched before this loop whose TERM was refused has no exit still
  # coming: there is nothing to wait for, so fall through to the disposition below.
  if [ "$shutdown" -eq 1 ] && [ "$signal_failed" -eq 1 ]; then
    status=0
  else
    # ash writes a bare job-status word to fd2 for a child killed BY a signal (reachable
    # through the pre-pid latch); a per-command redirect never reaches the traps' own fd2.
    wait "$radvd_pid" 2>/dev/null
    status=$?
  fi
  if [ "$sig_seen" -eq 1 ]; then
    sig_seen=0
    if [ "$shutdown" -eq 1 ]; then
      # Exit 0 either way: an explicit `docker stop` must not read as a crash to a
      # restart policy, so the refused delivery is reported rather than propagated.
      if [ "$signal_failed" -eq 1 ]; then
        printf 'level=warn msg="the TERM could not be delivered to radvd; a graceful stop cannot be confirmed"\n' >&2
      else
        # A second trapped signal interrupts this reap, and only an unsignalable child
        # licenses the graceful-stop line below.
        while kill -0 "$radvd_pid" 2>/dev/null; do
          wait "$radvd_pid" 2>/dev/null
        done
        printf 'level=info msg="radvd stopped on shutdown signal (SIGTERM/SIGINT)"\n' >&2
      fi
      exit 0
    fi
    # No flag armed means the trap refused its own delivery, so the child is still
    # serving: keep supervising it rather than reading the interruption as an exit.
    continue
  fi
  # Cleared before the next start: left set, a TERM landing in this gap takes
  # on_term's kill arm against an already-reaped child and logs a delivery failure
  # no path owes — reload resolves it at start_radvd's gate, exit has nothing to stop.
  radvd_pid=""

  if [ "$reload" -eq 1 ]; then
    reload=0
    printf 'level=info msg="reloading radvd (config re-read via restart)"\n' >&2
    check_config_directives
    start_radvd
    continue
  fi
  printf 'level=error msg="radvd exited; propagating exit for restart policy" status="%s"\n' "$status" >&2
  exit "$status"
done
