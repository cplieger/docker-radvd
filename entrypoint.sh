#!/bin/sh
# Supervises radvd rather than exec'ing it, so SIGHUP re-reads the config as root:
# CONTRIBUTING.md, "Design boundaries (please preserve)".
set -u

# The handlers' log stream: the reap block below redirects fd2 out from under them.
exec 3>&2

CONF="/etc/radvd/radvd.conf"

# Armed before preflight because PID 1 receives no default-disposition signal: a
# HUP/TERM during validation is latched here for start_radvd's pre-pid latch.
radvd_pid=""
reload=0
shutdown=0
# Set when a TERM to the child was refused, so the shutdown arm cannot claim a
# graceful stop it never observed. Scoped to one child: start_radvd clears it.
signal_failed=0
on_hup() {
  if [ "$shutdown" -eq 1 ]; then
    printf 'level=info msg="SIGHUP received during shutdown; reload ignored"\n' >&3
    return
  fi
  # The reload stops radvd before its replacement reads the config, so a bad or
  # absent config here would leave the container with no daemon: refuse and keep
  # serving the last good one. `radvd -c` rejects nothing the daemon accepts — it
  # forces debug level 1 (radvd.c:289-290) and short-circuits before setup_ifaces.
  hup_ct=""
  hup_rc=0
  if [ -f "$CONF" ]; then
    hup_ct=$(timeout 5 radvd -c -C "$CONF" 2>&1) || hup_rc=$?
  fi
  if ! [ -e "$CONF" ]; then
    printf 'level=error msg="SIGHUP reload refused: radvd.conf is absent; radvd keeps serving its last good config" path="%s"\n' "$CONF" >&3
    return
  fi
  if [ "$hup_rc" -ne 0 ]; then
    # Neither timeout call site passes -k, so an elapsed budget is 124 (GNU) or
    # 143 (BusyBox, the shipped one) and 137 is unreachable at both.
    if [ "$hup_rc" -eq 124 ] || [ "$hup_rc" -eq 143 ]; then
      printf 'level=error msg="SIGHUP reload refused: the config check did not finish within 5s; radvd keeps serving its last good config" path="%s"\n' "$CONF" >&3
    else
      printf 'level=error msg="SIGHUP reload refused: radvd rejected the mounted config; radvd keeps serving its last good config" path="%s"\n' "$CONF" >&3
      printf '%s\n' "$hup_ct" >&3
    fi
    return
  fi
  reload=1
  printf 'level=info msg="SIGHUP received; restarting radvd to reload config"\n' >&3
  if [ -n "$radvd_pid" ] && ! kill -TERM "$radvd_pid" 2>/dev/null; then
    printf 'level=error msg="failed to deliver TERM to radvd; the container may lack CAP_KILL, or the child was already reaped" pid="%s"\n' "$radvd_pid" >&3
  fi
}
on_term() {
  shutdown=1
  printf 'level=info msg="shutdown signal received; stopping radvd"\n' >&3
  if [ -n "$radvd_pid" ] && ! kill -TERM "$radvd_pid" 2>/dev/null; then
    signal_failed=1
    printf 'level=error msg="failed to deliver TERM to radvd; the container may lack CAP_KILL, or the child was already reaped" pid="%s"\n' "$radvd_pid" >&3
  fi
}
trap on_hup HUP
trap on_term TERM INT

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

RADVD_DEBUG_LEVEL="${RADVD_DEBUG_LEVEL:-0}"
case "$RADVD_DEBUG_LEVEL" in
  [0-5]) ;;
  *)
    bad_level=$(sanitize_log_value "$RADVD_DEBUG_LEVEL" 32)
    printf 'level=error msg="invalid RADVD_DEBUG_LEVEL; expected an integer 0-5" value="%s"\n' "$bad_level" >&2
    exit 1
    ;;
esac

# Warn-only except the non-regular-node refusal below, which exits 1 from both
# call sites: a single-node operator legitimately deploys without HA. Why HA needs
# these directives: CONTRIBUTING.md, "Design boundaries (please preserve)".
check_ha_directives() {
  # A FIFO with no writer blocks in open/read and a device node may return EOF
  # immediately (/dev/null does), so neither gives the bounded regular-file
  # snapshot this scan needs. No POSIX-sh operation can type-check and open a node
  # atomically, so the bounded read below is the backstop; one read serves every gate.
  warn_scan_degraded() {
    scan_err=$(sanitize_log_value "$1" 200)
    printf 'level=warn msg="unable to scan mounted radvd config; HA-directive validation is incomplete" err="%s" path="%s"\n' "$scan_err" "$CONF" >&2
  }
  if [ -e "$CONF" ] && ! [ -f "$CONF" ]; then
    printf 'level=error msg="radvd.conf is not a regular file" path="%s"\n' "$CONF" >&2
    exit 1
  fi
  # 5s: above any legitimate read of this config, below `docker stop`'s 10s grace.
  conf_snapshot=$({ timeout 5 cat "$CONF" 2>/dev/null; } 2>/dev/null)
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
  # radvd's scanner makes a double-quoted string one token (v2.21 scanner.l), so a
  # `#` inside one is content: a naive strip from the first `#` erases the `;` after
  # `AdvCaptivePortalAPI "…/#/login"` and the gates lose their anchor. Split on the
  # quote, not byte by byte: a char loop costs seconds on a multi-megabyte config.
  conf_scan=$(printf '%s\n' "$conf_snapshot" | awk '
    {
      gsub(/\r/, "")
      # radvd scanner.l:39 makes a string backslash-escape aware, so an ODD
      # number of \" inside a value would invert a naive quote split.
      gsub(/\\./, "@@")
      n = split($0, seg, "\"")
      out = ""
      for (i = 1; i <= n; i++) {
        s = seg[i]
        if (i % 2 == 1) {
          p = index(s, "#")
          if (p > 0) { out = out substr(s, 1, p - 1); break }
          out = out s
        }
        if (i < n) { out = out "\"" }
      }
      print out
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
      f_ignore_off = 0
      f_src = 0
      srcdepth = 0
      pend = ""
      bad = ""
    }
    function flush() {
      if (!entered) { return }
      if (!f_send) { print "no_sendadvert " iface }
      if (f_ignore_off) { print "ignore_off " iface }
      if (!f_src) { print "no_src " iface }
      if (bad != "") { print "bad_src " iface " " bad }
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
          if (lt == "interface") {
            flush()
            seen_iface = 1
            want_name = 1
          }
          pend = ""
          continue
        }
        if (depth != 1) {
          pend = ""
          continue
        }
        if (pend == "advsendadvert" && lt == "on") {
          f_send = 1
          pend = ""
          continue
        }
        if (pend == "ignoreifmissing" && lt == "off") {
          f_ignore_off = 1
          pend = ""
          continue
        }
        if (lt == "advsendadvert" || lt == "ignoreifmissing" || lt == "advrasrcaddress") {
          if (lt == "advrasrcaddress") { f_src = 1 }
          pend = lt
          continue
        }
        pend = ""
      }
    }
    END {
      flush()
      if (!seen_iface) { print "no_interface" }
    }
  ' | while read -r kind iface_name bad_addrs; do
    # iface= carries operator-supplied config text (upstream's scanner accepts
    # quoted, backslash-escaped STRING tokens), so it crosses bad='s trust boundary.
    case "$kind" in
      no_interface)
        printf 'level=warn msg="radvd.conf defines no interface; radvd will exit because at least one interface block is required" path="%s"\n' "$CONF" >&2
        ;;
      no_sendadvert)
        printf 'level=warn msg="no enabled AdvSendAdvert on directive found; radvd defaults it to off, so it will run and emit no router advertisements" iface="%s" path="%s"\n' "$(sanitize_log_value "$iface_name" 200)" "$CONF" >&2
        ;;
      ignore_off)
        printf 'level=warn msg="IgnoreIfMissing is explicitly off; on an HA backup radvd will exit or log errors when the AdvRASrcAddress link-local is absent (upstream default is on)" iface="%s" path="%s"\n' "$(sanitize_log_value "$iface_name" 200)" "$CONF" >&2
        ;;
      no_src)
        printf 'level=warn msg="no AdvRASrcAddress directive found in mounted radvd config (HA failover will not work correctly)" iface="%s" path="%s"\n' "$(sanitize_log_value "$iface_name" 200)" "$CONF" >&2
        ;;
      bad_src)
        printf 'level=warn msg="AdvRASrcAddress is set to a non-link-local address; RFC 4861 requires an RA source to be link-local (fe80::/10), so hosts will silently discard these RAs" bad="%s" iface="%s" path="%s"\n' "$(sanitize_log_value "$bad_addrs" 200)" "$(sanitize_log_value "$iface_name" 200)" "$CONF" >&2
        ;;
    esac
  done
}

if [ -r "$CONF" ]; then
  check_ha_directives
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
  radvd -C "$CONF" -n -m stderr -d "$RADVD_DEBUG_LEVEL" -u radvd &
  radvd_pid=$!
  # A signal delivered before radvd_pid was assigned set its flag but skipped the
  # kill; deliver it here so an early stop or reload is not swallowed.
  if [ "$shutdown" -eq 1 ] || [ "$reload" -eq 1 ]; then
    if ! kill -TERM "$radvd_pid" 2>/dev/null; then
      signal_failed=1
      printf 'level=error msg="failed to deliver TERM to radvd; the container may lack CAP_KILL, or the child was already reaped" pid="%s"\n' "$radvd_pid" >&2
    fi
  fi
}

printf 'level=info msg="starting radvd" config="%s" debug_level="%s"\n' "$CONF" "$RADVD_DEBUG_LEVEL" >&2
start_radvd

while :; do
  # A trapped signal interrupts wait before radvd has terminated; keep reaping so
  # the next start does not race a dying process. The inner wait refreshes status,
  # which a refused reload (neither flag set) would otherwise leave at 129.
  {
    wait "$radvd_pid"
    status=$?
    while kill -0 "$radvd_pid" 2>/dev/null; do
      wait "$radvd_pid"
      status=$?
    done
  } 2>/dev/null
  # Cleared as soon as the loop can no longer see the child: left set, a TERM in
  # this gap reports a CAP_KILL fault that is not there. The handlers skip an empty
  # radvd_pid and start_radvd's pre-pid latch delivers to the replacement.
  radvd_pid=""

  if [ "$shutdown" -eq 1 ]; then
    # Exit 0 either way: an explicit `docker stop` must not read as a crash to a
    # restart policy, so the refused delivery is reported rather than propagated.
    if [ "$signal_failed" -eq 1 ]; then
      printf 'level=warn msg="the TERM could not be delivered to radvd; a graceful stop cannot be confirmed"\n' >&2
    else
      printf 'level=info msg="radvd stopped on shutdown signal (SIGTERM/SIGINT)"\n' >&2
    fi
    exit 0
  fi
  if [ "$reload" -eq 1 ]; then
    reload=0
    printf 'level=info msg="reloading radvd (config re-read via restart)"\n' >&2
    check_ha_directives
    start_radvd
    continue
  fi
  printf 'level=error msg="radvd exited; propagating exit for restart policy" status="%s"\n' "$status" >&2
  exit "$status"
done
