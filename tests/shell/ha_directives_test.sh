#!/usr/bin/env bash
# check_ha_directives(): the validator behind the HA warnings, and the bulk of
# entrypoint.sh. Warn-only except the refusal of a node radvd itself cannot open,
# so each case pins which line fires for which config shape and, just as
# load-bearing, which shapes stay SILENT — a false warning against a valid config
# is how a real one gets ignored. Its only input is the CONF global, so every case
# builds a fresh config dir. The host's sed/grep/awk/tr stand in for the image's
# BusyBox ones, so a case asserts an OUTCOME (which line, silence, one parseable
# line), never a tool-specific substitution; only case 17 stubs anything, and only
# the two process boundaries whose STATUS is the subject there.
#
# Lint directives, each against a stated guarantee rather than an assumption:
#   SC2015 - `cond && ok || no` cannot mis-fire: lib.sh's ok/no/skip return 0.
#   SC2034 - CONF is the INPUT the extracted code reads through load_function.
#   SC2016 - run_check's bash -c body is single-quoted so nothing expands here.
# shellcheck disable=SC2015,SC2034,SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

load_function check_ha_directives
# warn_scan_degraded delegates to the top-level sanitize_log_value, so the
# extraction needs it too — without it the degraded-scan path dies with
# "command not found" and the sanitizer assertion reports a wrong outcome rather
# than a missing dependency.
load_function sanitize_log_value
# The same extractions, kept as files for run_check's bounded subshell below.
SRC=$(extract_function check_ha_directives "$WORK/check_ha_directives.sh") || exit 1
SANITIZER=$(extract_function sanitize_log_value "$WORK/sanitize_log_value.sh") || exit 1

LOG="$WORK/log"

setup() {
  DIR=$(mktemp -d "$WORK/conf.XXXXXX")
  CONF="$DIR/radvd.conf"
}

# A lost non-regular-file guard would leave the validator's own 5s read bound as
# the only thing between its cat probe and a FIFO's EOF that never comes, so every
# run is bounded here as well: a hang becomes a non-zero status instead of a wedged
# test run. `timeout` needs a COMMAND, not a shell function, hence the bash -c
# re-entry sourcing the already-extracted file.
run_check() {
  _rc=0
  timeout 5 bash -c '
    set -u
    . "$1"
    . "$2"
    CONF=$3
    check_ha_directives
  ' _ "$SANITIZER" "$SRC" "$CONF" 2>"$LOG" || _rc=$?
}

logged() {
  grep -Fq "$1" "$LOG"
}

warn_count() {
  grep -c 'level=warn' "$LOG"
}

# --- 1. the happy path is SILENT --------------------------------------------------
# Without this control, every warning assertion below could pass against a
# validator that warns on everything.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fe80::cc32:57ff:feb5:85bf; };\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "a correct HA config (IgnoreIfMissing on + link-local AdvRASrcAddress) is silent" \
  || no "happy path silent" "rc=$_rc, log: $(cat "$LOG")"

# --- 2. the whole grammar on ONE line is still recognised --------------------------
# radvd's grammar is whitespace-insensitive and the gates promise a statement
# boundary (start, ;, { or }) is enough. If the boundary alternation broke, this
# valid one-liner would draw two false missing-directive warnings.
setup
printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { febf::1; }; };\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "a valid one-line nested config is silent (mid-line directives found), with febf::1 accepted at the top of fe80::/10" \
  || no "one-line config" "rc=$_rc, log: $(cat "$LOG")"

# The bare name at end-of-line, with the opening brace on the next line. CONTRIBUTING
# records this spelling as deliberately accepted, so it must stay silent.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress\n  {\n    fe80::1;\n  };\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "a bare AdvRASrcAddress at end-of-line with the brace on the next line is silent" \
  || no "bare name at EOL" "rc=$_rc, log: $(cat "$LOG")"

# The no-space form, also recorded in CONTRIBUTING as deliberately accepted.
setup
printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress{fe80::1;}; };\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "the no-space AdvRASrcAddress{...} form is silent" \
  || no "no-space form" "rc=$_rc, log: $(cat "$LOG")"

# --- 3. case-insensitive, because radvd's flex scanner is caseless ----------------
setup
printf 'INTERFACE eth0 { IGNOREIFMISSING ON; ADVRASRCADDRESS { FE80::1; }; };\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "an all-uppercase valid config is silent (gates and scanner are caseless)" \
  || no "case-insensitivity" "log: $(cat "$LOG")"

# --- 4. CRLF line endings do not corrupt the address tokens -----------------------
# The block must SPAN lines: on a one-line block the close-brace strip discards the
# CR before tokenization, so only a multi-line block leaves a bare "\r" token for
# the tokenizer — which the address-token trim (space/tab only) cannot remove, and
# a correct link-local config then draws a false non-link-local warning.
setup
printf 'interface eth0 {\r\n  IgnoreIfMissing on;\r\n  AdvRASrcAddress {\r\n    fe80::1;\r\n  };\r\n};\r\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "a CRLF config with a correct link-local source is silent" \
  || no "CRLF handling" "log: $(cat "$LOG")"

# --- 5. a directive NAME must sit on a statement boundary -------------------------
# "MyIgnoreIfMissing on" contains the directive as a substring; the boundary
# anchor is what keeps it from satisfying the gate.
setup
printf 'interface eth0 {\n  MyIgnoreIfMissing on;\n  AdvRASrcAddress { fe80::1; };\n};\n' >"$CONF"
run_check
logged 'msg="no enabled IgnoreIfMissing on directive found' \
  && ok "a substring like MyIgnoreIfMissing does not satisfy the IgnoreIfMissing gate" \
  || no "boundary anchor" "log: $(cat "$LOG")"

# --- 6. a commented-out IgnoreIfMissing does not count ----------------------------
# The bait carries a statement boundary INSIDE the comment (`; Ignore...`): without
# comment stripping that `;` satisfies the gate's boundary anchor and the gate
# reads a fully commented line as configured HA. A bare `# IgnoreIfMissing on`
# would be rejected by the boundary anchor alone and prove nothing about the strip.
setup
printf 'interface eth0 {\n  # retired 2024; IgnoreIfMissing on;\n  AdvRASrcAddress { fe80::1; };\n};\n' >"$CONF"
run_check
logged 'msg="no enabled IgnoreIfMissing on directive found' \
  && ok "a commented-out IgnoreIfMissing still warns (comments are stripped first)" \
  || no "comment stripping" "log: $(cat "$LOG")"

# --- 7. IgnoreIfMissing must be ON ------------------------------------------------
setup
printf 'interface eth0 {\n  IgnoreIfMissing off;\n  AdvRASrcAddress { fe80::1; };\n};\n' >"$CONF"
run_check
logged 'msg="no enabled IgnoreIfMissing on directive found' \
  && ok "IgnoreIfMissing off is not accepted by a substring match (the value must be on)" \
  || no "off rejected" "log: $(cat "$LOG")"

# --- 8. THE CLASSIC HA MISTAKE: AdvRASrcAddress on a non-link-local address -------
# RFC 4861 §6.1.2: hosts silently discard an RA sourced from a non-link-local
# address. radvd emits, tcpdump shows traffic, nothing autoconfigures — this
# warning is the only artifact that names the cause.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fd00::78; };\n};\n' >"$CONF"
run_check
logged 'msg="AdvRASrcAddress is set to a non-link-local address' && logged 'fd00::78' \
  && ok "a ULA AdvRASrcAddress warns as non-link-local, naming the address" \
  || no "ULA source warned" "log: $(cat "$LOG")"

setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fec0::1; };\n};\n' >"$CONF"
run_check
logged 'msg="AdvRASrcAddress is set to a non-link-local address' && logged 'fec0::1' \
  && ok "a site-local fec0:: source warns: it is one hex digit outside fe80::/10, which is what [89ab] decides" \
  || no "site-local source warned" "log: $(cat "$LOG")"

# --- 9. a correct block must not MASK a broken sibling ----------------------------
# Two blocks in one radvd.conf: eth0's correct block, then the global-VIP mistake on
# a later line. A correct block seen first must not stop the scan.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fe80::1; };\n};\ninterface eth1 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fd00::78; };\n};\n' >"$CONF"
run_check
logged 'msg="AdvRASrcAddress is set to a non-link-local address' && logged 'fd00::78' \
  && ok "a broken sibling block on a later line is not masked by a correct one, and is named" \
  || no "multi-block sibling" "log: $(cat "$LOG")"

# Same line: a correct block followed by a wrong one. Only the same-line re-scan
# branch of the awk state machine reaches the second block.
setup
printf 'interface eth0 { AdvRASrcAddress { fe80::1; }; }; interface eth1 { AdvRASrcAddress { fd00::78; }; };\n' >"$CONF"
run_check
logged 'fd00::78' \
  && ok "a broken sibling BLOCK on the same line is still scanned (same-line re-scan)" \
  || no "same-line sibling" "log: $(cat "$LOG")"

# --- 10. no false warning from a trailing same-line directive ---------------------
# `}; MinRtrAdvInterval 30;` after the address block must not be parsed as an
# address. This is the false-POSITIVE guard; cases 8/9 keep it honest (the file
# cannot pass by never warning).
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fe80::1; }; MinRtrAdvInterval 30;\n};\n' >"$CONF"
run_check
[ ! -s "$LOG" ] \
  && ok "a trailing same-line directive after the block close is not read as an address" \
  || no "trailing directive" "log: $(cat "$LOG")"

# --- 11. missing AdvRASrcAddress warns (HA failover would not work) ---------------
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvSendAdvert on;\n};\n' >"$CONF"
run_check
logged 'msg="no AdvRASrcAddress directive found' \
  && ok "a config without AdvRASrcAddress warns that HA failover will not work" \
  || no "missing AdvRASrcAddress" "log: $(cat "$LOG")"

# --- 12. a non-regular config node is REFUSED, and PID 1 must not hang -----------
# A FIFO at radvd.conf: the regular-file probe refuses it before the read, which
# without the probe would stall until the bounded read gave up and then degrade to
# a warning — while radvd's own open of the same node blocks with no bound at all,
# leaving a container the healthcheck calls healthy while it emits nothing.
# run_check's timeout turns a hang into a failure here, and its bash -c gives
# `exit 1` a process boundary to reach instead of this file.
setup
rm -f "$CONF"
mkfifo "$CONF"
run_check
[ "$_rc" -eq 1 ] && logged 'msg="radvd.conf is not a regular file' \
  && [ "$(wc -l <"$LOG")" -eq 1 ] && [ "$(warn_count)" -eq 0 ] \
  && ! logged 'no enabled IgnoreIfMissing' \
  && ok "a FIFO at radvd.conf is refused with exit 1 on one line, without hanging or misdiagnosing" \
  || no "FIFO refused" "rc=$_rc, log: $(cat "$LOG")"

# An ABSENT config is not a refusal: the reload call site has no readability gate,
# so the `-e` half of the probe is what keeps a config removed since startup on
# the degraded-scan path instead of exiting 1 after radvd has already been stopped.
setup
rm -f "$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="unable to scan mounted radvd config' \
  && ! logged 'msg="radvd.conf is not a regular file' \
  && ok "an absent radvd.conf degrades instead of being refused as non-regular" \
  || no "absent config degraded" "rc=$_rc, log: $(cat "$LOG")"

# The unreadable-file arm of the same guard reaches the READ, not the -f probe —
# but root reads a chmod-000 file, so the branch cannot be provoked as root and
# asserting it would fail for a root maintainer while passing in CI.
setup
printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$CONF"
if [ "$(id -u)" -eq 0 ]; then
  skip "an unreadable radvd.conf routes to the degraded-scan warning" "root reads a chmod-000 file, so the refusal is unreachable"
else
  chmod 000 "$CONF"
  run_check
  [ "$_rc" -eq 0 ] && logged 'msg="unable to scan mounted radvd config' \
    && logged 'Permission denied' \
    && ok "an unreadable radvd.conf degrades via the failed read instead of misdiagnosing" \
    || no "unreadable degraded" "rc=$_rc, log: $(cat "$LOG")"
  chmod 644 "$CONF"
fi

# --- 13. hostile bytes inside an ADDRESS token reach the boundary sanitizer --------
# The bad= field names operator-supplied address tokens, so the sanitize_log_value
# call on the shipped path is the only thing standing between a config value and the
# structured log line. A quote inside the address survives tokenization (the splitter
# cuts on ';' and trims only space/tab), so it reaches bad= as part of the token.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fd00::"78; };\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="AdvRASrcAddress is set to a non-link-local address' \
  && [ "$(wc -l <"$LOG")" -eq 1 ] && ! grep -Fq 'fd00::"78' "$LOG" \
  && grep -q 'fd00::?78' "$LOG" \
  && ok "a quote inside the ADDRESS token named in bad= is neutralized" \
  || no "quote in the address token" "lines=$(wc -l <"$LOG"), log: $(cat "$LOG")"

# The control-byte arm of the same sanitizer, which the quote mapping cannot cover:
# a control byte inside the address token. The one-line oracle is what the
# \040-\176 substitution holds together.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fd00::\017 78; };\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="AdvRASrcAddress is set to a non-link-local address' \
  && [ "$(wc -l <"$LOG")" -eq 1 ] && ! grep -q 'fd00::'"$(printf '\017')" "$LOG" \
  && ok "a control byte inside the address token is neutralized and the warning stays one line" \
  || no "control byte in the address token" "lines=$(wc -l <"$LOG"), log: $(cat "$LOG")"

# --- 14. a directive SPLIT across lines is still seen ------------------------------
# radvd's lexer discards newlines, so `IgnoreIfMissing` with its value `on;` on the
# next line is valid config. The gates match a newline-folded stream for that reason;
# a line-oriented gate reads this valid config as missing HA directives.
setup
printf 'interface eth0 {\n  IgnoreIfMissing\n  on;\n  AdvRASrcAddress { fe80::1; };\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "IgnoreIfMissing with its value on the next line is silent (newlines are folded)" \
  || no "line-spanning directive" "rc=$_rc, log: $(cat "$LOG")"

# --- 15. an UNCLOSED AdvRASrcAddress block cannot log an unbounded bad= field ------
# A block whose closing `}` is missing leaves the scanner in-block, so every
# following directive is tokenized as an address and the whole remainder of the
# config lands in one bad= field. The cap on the shipped call is what bounds that
# record, and the marker is what stops a cut list from reading as a complete one.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress {\n  MinRtrAdvInterval 30;\n  MaxRtrAdvInterval 100;\n  AdvSendAdvert on;\n  AdvManagedFlag off;\n  AdvOtherConfigFlag off;\n  prefix 2001:db8:1::/64;\n  AdvOnLink on;\n  AdvAutonomous on;\n  AdvValidLifetime 86400;\n  AdvPreferredLifetime 14400;\n  RDNSS 2001:db8:1::53;\n' >"$CONF"
run_check
bad=$(sed -n 's/.*bad="\([^"]*\)".*/\1/p' "$LOG")
payload=${bad%"[truncated]"}
[ "$_rc" -eq 0 ] && [ "$(wc -l <"$LOG")" -eq 1 ] \
  && logged 'msg="AdvRASrcAddress is set to a non-link-local address' \
  && [ "${#payload}" -eq 200 ] && [ "$payload" != "$bad" ] \
  && ok "an unclosed AdvRASrcAddress block warns once, with bad= capped at 200 and marked truncated" \
  || no "unclosed block cap" "lines=$(wc -l <"$LOG"), payload=${#payload}, bad='$bad'"

# --- 16. a config defining NO INTERFACE warns, and the directive scan still runs ---
# A config defining no interface is a foretold radvd failure (its grammar requires
# at least one interface block), not a reason to skip the scan — both call sites
# reach this warning, so a config emptied between startup and a HUP reload says so
# on the reload too.
setup
: >"$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="radvd.conf defines no interface' \
  && logged 'msg="no enabled IgnoreIfMissing on directive found' \
  && logged 'msg="no AdvRASrcAddress directive found' \
  && ok "an empty config warns that radvd will exit, and the HA-directive scan still runs" \
  || no "empty config warn" "rc=$_rc, log: $(cat "$LOG")"

setup
printf '# interface eth0 { AdvSendAdvert on; };\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="radvd.conf defines no interface' \
  && ok "a fully commented-out config warns (comments define no interface)" \
  || no "comment-only config warn" "rc=$_rc, log: $(cat "$LOG")"

setup
printf 'AdvSendAdvert on;\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="radvd.conf defines no interface' \
  && ok "top-level directives with no interface block warn (radvd's grammar rejects it)" \
  || no "top-level-only config warn" "rc=$_rc, log: $(cat "$LOG")"

# --- 17. an elapsed read budget stays bounded, on the status BusyBox produces ------
# BusyBox timeout reports expiry as 143, not GNU's translated 124. Drive that
# process-boundary result directly and record whether the failed-read arm falls
# through to an unbounded diagnostic cat.
setup
printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$CONF"
calls="$WORK/timeout-143-calls"
: >"$calls"
timeout() {
  printf 'timeout %s\n' "$*" >>"$calls"
  return 143
}
cat() {
  printf 'cat %s\n' "$*" >>"$calls"
  return 99
}
_rc=0
check_ha_directives 2>"$LOG" || _rc=$?
timeout_calls=$(grep -c '^timeout ' "$calls" || true)
cat_calls=$(grep -c '^cat ' "$calls" || true)
unset -f timeout cat
[ "$_rc" -eq 0 ] && [ "$timeout_calls" -ge 1 ] && [ "$cat_calls" -eq 0 ] \
  && logged 'read of the config exceeded 5s' \
  && ok "BusyBox timeout expiry stays bounded and emits the exceeded-budget warning without a direct re-read" \
  || no "BusyBox timeout expiry" "rc=$_rc, timeout_calls=$timeout_calls, cat_calls=$cat_calls, log: $(cat "$LOG")"

report
