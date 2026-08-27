#!/usr/bin/env bash
# check_config_directives(): the validator behind the config warnings, and the bulk of
# entrypoint.sh. Warn-only except the refusal of a node radvd itself cannot open,
# so each case pins which line fires for which config shape and, just as
# load-bearing, which shapes stay SILENT — a false warning against a valid config
# is how a real one gets ignored. Its only input is the CONF global, so every case
# builds a fresh config dir. The host's sed/grep/awk/tr stand in for the image's
# BusyBox ones, so a case asserts an OUTCOME (which line, silence, one parseable
# line), never a tool-specific substitution; only case 15 stubs anything, and only
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

load_function check_config_directives
# warn_scan_degraded delegates to the top-level sanitize_log_value, so the
# extraction needs it too — without it the degraded-scan path dies with
# "command not found" and the sanitizer assertion reports a wrong outcome rather
# than a missing dependency.
load_function sanitize_log_value
# The same extractions, kept as files for run_check's bounded subshell below.
SRC=$(extract_function check_config_directives "$WORK/check_config_directives.sh") || exit 1
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
    check_config_directives
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
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvSendAdvert on;\n  AdvRASrcAddress { fe80::cc32:57ff:feb5:85bf; };\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "a correct HA config (AdvSendAdvert on + link-local AdvRASrcAddress) is silent" \
  || no "happy path silent" "rc=$_rc, log: $(cat "$LOG")"

# --- 2. the whole grammar on ONE line is still recognised --------------------------
# radvd's grammar is whitespace-insensitive and the gates promise a statement
# boundary (start, ;, { or }) is enough. If the boundary alternation broke, this
# valid one-liner would draw two false missing-directive warnings.
setup
printf 'interface eth0 { IgnoreIfMissing on; AdvSendAdvert on; AdvRASrcAddress { febf::1; }; };\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "a valid one-line nested config is silent (mid-line directives found), with febf::1 accepted at the top of fe80::/10" \
  || no "one-line config" "rc=$_rc, log: $(cat "$LOG")"

# The bare name at end-of-line, with the opening brace on the next line. CONTRIBUTING
# records this spelling as deliberately accepted, so it must stay silent.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvSendAdvert on;\n  AdvRASrcAddress\n  {\n    fe80::1;\n  };\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "a bare AdvRASrcAddress at end-of-line with the brace on the next line is silent" \
  || no "bare name at EOL" "rc=$_rc, log: $(cat "$LOG")"

# The no-space form, also recorded in CONTRIBUTING as deliberately accepted.
setup
printf 'interface eth0 { IgnoreIfMissing on; AdvSendAdvert on; AdvRASrcAddress{fe80::1;}; };\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "the no-space AdvRASrcAddress{...} form is silent" \
  || no "no-space form" "rc=$_rc, log: $(cat "$LOG")"

# --- 3. case-insensitive, because radvd's flex scanner is caseless ----------------
setup
printf 'INTERFACE eth0 { IGNOREIFMISSING ON; ADVSENDADVERT ON; ADVRASRCADDRESS { FE80::1; }; };\n' >"$CONF"
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
printf 'interface eth0 {\r\n  IgnoreIfMissing on;\r\n  AdvSendAdvert on;\r\n  AdvRASrcAddress {\r\n    fe80::1;\r\n  };\r\n};\r\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "a CRLF config with a correct link-local source is silent" \
  || no "CRLF handling" "log: $(cat "$LOG")"

# --- 5. a directive NAME must sit on a statement boundary -------------------------
# "MyAdvSendAdvert on" contains the directive as a substring; the statement
# boundary is what keeps it from satisfying the gate.
setup
printf 'interface eth0 {\n  MyAdvSendAdvert on;\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fe80::1; };\n};\n' >"$CONF"
run_check
logged 'msg="no enabled AdvSendAdvert on directive found' \
  && ok "a substring like MyAdvSendAdvert does not satisfy the AdvSendAdvert gate" \
  || no "boundary anchor" "log: $(cat "$LOG")"

# --- 6. a commented-out AdvSendAdvert does not count ------------------------------
# The bait carries a statement boundary INSIDE the comment (`; AdvSend...`): without
# comment stripping that `;` opens a fresh statement and the gate reads a fully
# commented line as configured. A bare `# AdvSendAdvert on` would be rejected by
# the statement boundary alone and prove nothing about the strip.
setup
printf 'interface eth0 {\n  # retired 2024; AdvSendAdvert on;\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fe80::1; };\n};\n' >"$CONF"
run_check
logged 'msg="no enabled AdvSendAdvert on directive found' \
  && ok "a commented-out AdvSendAdvert still warns (comments are stripped first)" \
  || no "comment stripping" "log: $(cat "$LOG")"

# --- 7. THE CLASSIC HA MISTAKE: AdvRASrcAddress on a non-link-local address -------
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

# --- 8. a correct block must not MASK a broken sibling ----------------------------
# Two blocks in one radvd.conf: eth0's correct block, then the global-VIP mistake on
# a later line. A correct block seen first must not stop the scan.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fe80::1; };\n};\ninterface eth1 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fd00::78; };\n};\n' >"$CONF"
run_check
logged 'msg="AdvRASrcAddress is set to a non-link-local address' && logged 'fd00::78' \
  && ok "a broken sibling block on a later line is not masked by a correct one, and is named" \
  || no "multi-block sibling" "log: $(cat "$LOG")"

# Same line: a correct block followed by a wrong one. The whole config is one line,
# so only a walk that carries its brace depth across a block close reaches the
# second block at all.
setup
printf 'interface eth0 { AdvRASrcAddress { fe80::1; }; }; interface eth1 { AdvRASrcAddress { fd00::78; }; };\n' >"$CONF"
run_check
logged 'fd00::78' \
  && ok "a broken sibling BLOCK on the same line is still scanned (same-line re-scan)" \
  || no "same-line sibling" "log: $(cat "$LOG")"

# --- 9. no false warning from a trailing same-line directive ---------------------
# `}; MinRtrAdvInterval 30;` after the address block must not be parsed as an
# address. This is the false-POSITIVE guard; cases 7/8 keep it honest (the file
# cannot pass by never warning).
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvSendAdvert on;\n  AdvRASrcAddress { fe80::1; }; MinRtrAdvInterval 30;\n};\n' >"$CONF"
run_check
[ ! -s "$LOG" ] \
  && ok "a trailing same-line directive after the block close is not read as an address" \
  || no "trailing directive" "log: $(cat "$LOG")"

# --- 10. missing AdvRASrcAddress warns (HA failover would not work) ---------------
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvSendAdvert on;\n};\n' >"$CONF"
run_check
logged 'msg="no AdvRASrcAddress directive found' \
  && ok "a config without AdvRASrcAddress warns that HA failover will not work" \
  || no "missing AdvRASrcAddress" "log: $(cat "$LOG")"

# --- 11. a non-regular config node is REFUSED, and PID 1 must not hang -----------
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
  && ! logged 'msg="unable to scan mounted radvd config' \
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

# --- 12. hostile bytes inside an ADDRESS token reach the boundary sanitizer --------
# The bad= field names operator-supplied address tokens, so the sanitize_log_value
# call on the shipped path is the only thing standing between a config value and the
# structured log line. A quote cannot be the bait: the lexer owns it, so a `"` inside
# an address opens a string and no quote reaches bad= at all. A control byte INSIDE
# the token does reach it, and must be neutralized without splitting the token.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvSendAdvert on;\n  AdvRASrcAddress { fd00::\017x78; };\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="AdvRASrcAddress is set to a non-link-local address' \
  && [ "$(wc -l <"$LOG")" -eq 1 ] && ! grep -q 'fd00::'"$(printf '\017')" "$LOG" \
  && grep -q 'bad="fd00:: x78"' "$LOG" \
  && ok "a control byte inside the ADDRESS token named in bad= is neutralized in place" \
  || no "mid-token control byte in bad=" "lines=$(wc -l <"$LOG"), log: $(cat "$LOG")"

# The control-byte arm of the same sanitizer, which the quote mapping cannot cover:
# a control byte inside the address token. The one-line oracle is what the
# \040-\176 substitution holds together.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvSendAdvert on;\n  AdvRASrcAddress { fd00::\017 78; };\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="AdvRASrcAddress is set to a non-link-local address' \
  && [ "$(wc -l <"$LOG")" -eq 1 ] && ! grep -q 'fd00::'"$(printf '\017')" "$LOG" \
  && ok "a control byte inside the address token is neutralized and the warning stays one line" \
  || no "control byte in the address token" "lines=$(wc -l <"$LOG"), log: $(cat "$LOG")"

# The interface NAME is the third config-to-log crossing on this path: radvd's
# scanner accepts a quoted, backslash-escaped STRING token there (scanner.l,
# gram.y), so the name reaching iface= is operator-supplied text and not a
# kernel-validated device name. A control byte inside it must not reach the log
# stream raw.
setup
printf 'interface eth\017x {\n  AdvSendAdvert on;\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ "$(wc -l <"$LOG")" -eq 1 ] \
  && logged 'msg="no AdvRASrcAddress directive found' \
  && ! grep -q 'iface="eth'"$(printf '\017')" "$LOG" \
  && grep -q 'iface="eth x"' "$LOG" \
  && ok "a control byte in the interface NAME is neutralized in the iface= field" \
  || no "control byte in the interface name" "lines=$(wc -l <"$LOG"), log: $(cat "$LOG")"

# scanner.l's `string` macro is `[a-zA-Z0-9...]+|L?\"(\\.|[^\\"])*\"` (v2.21), so the
# quotes are INSIDE the match and reach yylval.str verbatim: radvd's own name for this
# interface is the 6-byte `"eth0"`, not the 4-byte `eth0`. The scan must report that,
# because an operator told `eth0` would look for a device radvd never asked about.
# The two `?` in the expected value ARE those quotes: sanitize_log_value maps `"` to
# `?` 1:1, since an unescaped quote inside a logfmt value="..." field truncates the
# record, and a 1:1 map keeps every later byte at its own offset. Assert the sanitized
# spelling AND that the bare 4-byte name never appears, so a scanner that goes back to
# stripping the quotes fails here.
setup
printf 'interface "eth0" {\n  AdvSendAdvert on;\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ "$(wc -l <"$LOG")" -eq 1 ] \
  && grep -q 'iface="?eth0?"' "$LOG" \
  && ! grep -q 'iface="eth0"' "$LOG" \
  && ok "a quoted interface name keeps its quotes, as radvd counts them, and stays parseable" \
  || no "quoted interface name" "lines=$(wc -l <"$LOG"), log: $(cat "$LOG")"

# An EMPTY quoted name is a real name to radvd (the 2-byte `""`), so the block must
# still be scanned. Stripping the quotes made it the empty string, which left `entered`
# unset and silently dropped every per-interface warning: total silence for a
# misconfigured block.
setup
printf 'interface "" {\n  AdvCaptivePortalAPI "x";\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ "$(wc -l <"$LOG")" -eq 2 ] \
  && logged 'msg="no enabled AdvSendAdvert on directive found' \
  && logged 'msg="no AdvRASrcAddress directive found' \
  && grep -cq 'iface="??"' "$LOG" \
  && ok "an empty quoted interface name is still a name, so its block is not silently skipped" \
  || no "empty quoted interface name" "lines=$(wc -l <"$LOG"), log: $(cat "$LOG")"

# --- 13. a directive SPLIT across lines is still seen ------------------------------
# radvd's lexer discards newlines, so `AdvSendAdvert` with its value `on;` on the
# next line is valid config. The gates match a newline-folded stream for that reason;
# a line-oriented gate reads this valid config as missing HA directives.
setup
printf 'interface eth0 {\n  AdvSendAdvert\n  on;\n  AdvRASrcAddress { fe80::1; };\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "AdvSendAdvert with its value on the next line is silent (newlines are folded)" \
  || no "line-spanning directive" "rc=$_rc, log: $(cat "$LOG")"

# --- 14. an UNCLOSED AdvRASrcAddress block cannot log an unbounded bad= field ------
# A block whose closing `}` is missing leaves the scanner in-block, so every
# following directive is tokenized as an address and the whole remainder of the
# config lands in one bad= field. The cap on the shipped call is what bounds that
# record, and the marker is what stops a cut list from reading as a complete one.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvSendAdvert on;\n  AdvRASrcAddress {\n  MinRtrAdvInterval 30;\n  MaxRtrAdvInterval 100;\n  AdvSendAdvert on;\n  AdvManagedFlag off;\n  AdvOtherConfigFlag off;\n  prefix 2001:db8:1::/64;\n  AdvOnLink on;\n  AdvAutonomous on;\n  AdvValidLifetime 86400;\n  AdvPreferredLifetime 14400;\n  RDNSS 2001:db8:1::53;\n' >"$CONF"
run_check
bad=$(sed -n 's/.*bad="\([^"]*\)".*/\1/p' "$LOG")
payload=${bad%"[truncated]"}
[ "$_rc" -eq 0 ] && [ "$(wc -l <"$LOG")" -eq 1 ] \
  && logged 'msg="AdvRASrcAddress is set to a non-link-local address' \
  && [ "${#payload}" -eq 200 ] && [ "$payload" != "$bad" ] \
  && ok "an unclosed AdvRASrcAddress block warns once, with bad= capped at 200 and marked truncated" \
  || no "unclosed block cap" "lines=$(wc -l <"$LOG"), payload=${#payload}, bad='$bad'"

# --- 15. an elapsed read budget stays bounded, on the status BusyBox produces ------
# BusyBox timeout reports expiry as 143, not GNU's translated 124. Drive that
# process-boundary result directly and record whether the failed-read arm falls
# through to an unbounded diagnostic cat.
setup
printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$CONF"
calls="$WORK/timeout-143-calls"
: >"$calls"
# Both stubs shadow the external commands the runtime-loaded check_config_directives
# invokes, so their call site is not in this file for shellcheck to see.
# shellcheck disable=SC2329
timeout() {
  printf 'timeout %s\n' "$*" >>"$calls"
  return 143
}
# shellcheck disable=SC2329
cat() {
  printf 'cat %s\n' "$*" >>"$calls"
  return 99
}
_rc=0
check_config_directives 2>"$LOG" || _rc=$?
timeout_calls=$(grep -c '^timeout ' "$calls" || true)
cat_calls=$(grep -c '^cat ' "$calls" || true)
unset -f timeout cat
[ "$_rc" -eq 0 ] && [ "$timeout_calls" -ge 1 ] && [ "$cat_calls" -eq 0 ] \
  && logged 'read of the config exceeded 5s' \
  && ok "BusyBox timeout expiry stays bounded and emits the exceeded-budget warning without a direct re-read" \
  || no "BusyBox timeout expiry" "rc=$_rc, timeout_calls=$timeout_calls, cat_calls=$cat_calls, log: $(cat "$LOG")"

# --- 16. text inside a QUOTED VALUE is data, and must change no HA decision -------
# radvd's scanner makes a double-quoted value ONE token (v2.21 scanner.l), so its
# bytes configure nothing. The bait is a complete HA config -- statement
# boundaries, directive names, values and an address block -- inside an
# AdvCaptivePortalAPI value, on an interface carrying neither real directive. The
# oracle is DIFFERENTIAL: the same config with an ordinary URL must draw exactly
# the same warnings. That is what keeps the case honest however the individual
# gates are worded, where a silence-only assertion would pin one wording. Compared
# on the msg= set, because path= names each case's own temp dir, and the plain
# run's set is required non-empty so two empty sets cannot compare equal.
msg_set() {
  sed -n 's/.*\(msg="[^"]*"\).*/\1/p' "$1" | sort
}
setup
printf 'interface eth0 {\n  AdvCaptivePortalAPI "https://portal.example/; AdvSendAdvert on; AdvRASrcAddress { fe80::1; };";\n};\n' >"$CONF"
run_check
bait_rc=$_rc
msg_set "$LOG" >"$WORK/bait.msgs"
setup
printf 'interface eth0 {\n  AdvCaptivePortalAPI "https://portal.example/login";\n};\n' >"$CONF"
run_check
msg_set "$LOG" >"$WORK/plain.msgs"
[ "$bait_rc" -eq 0 ] && [ "$_rc" -eq 0 ] && [ -s "$WORK/plain.msgs" ] \
  && cmp -s "$WORK/bait.msgs" "$WORK/plain.msgs" \
  && ok "directive-shaped text inside a quoted value changes no HA decision" \
  || no "quoted payload treated as syntax" "bait_rc=$bait_rc, rc=$_rc, bait=[$(tr '\n' ' ' <"$WORK/bait.msgs")], plain=[$(tr '\n' ' ' <"$WORK/plain.msgs")]"

# The case above baits with a MULTI-WORD payload, whose interior whitespace is masked
# on its own, so it passed even while a SINGLE-WORD payload did not: a lone quoted
# word carries no byte the mask touches, so stripping the quotes left it
# indistinguishable from a bare directive and it satisfied the AdvRASrcAddress gate.
# radvd returns STRING for `"AdvRASrcAddress"` and T_RASRCADDRESS only for the bare
# spelling, so the two must not agree here either. Same differential oracle.
setup
printf 'interface eth0 {\n  AdvSendAdvert on;\n  AdvCaptivePortalAPI "AdvRASrcAddress";\n};\n' >"$CONF"
run_check
word_rc=$_rc
msg_set "$LOG" >"$WORK/word.msgs"
setup
printf 'interface eth0 {\n  AdvSendAdvert on;\n  AdvCaptivePortalAPI "https://portal.example/login";\n};\n' >"$CONF"
run_check
msg_set "$LOG" >"$WORK/word-plain.msgs"
[ "$word_rc" -eq 0 ] && [ "$_rc" -eq 0 ] && [ -s "$WORK/word-plain.msgs" ] \
  && cmp -s "$WORK/word.msgs" "$WORK/word-plain.msgs" \
  && ok "a single-word quoted value cannot satisfy a directive gate either" \
  || no "single-word quoted payload satisfied a gate" "word_rc=$word_rc, rc=$_rc, word=[$(tr '\n' ' ' <"$WORK/word.msgs")], plain=[$(tr '\n' ' ' <"$WORK/word-plain.msgs")]"

# --- 17. a quoted value WRAPPED across lines is still ONE token -------------------
# scanner.l:39 negates only the quote, so radvd's string token spans newlines: a
# value opened on one line and closed on another carries every line between it as
# data. A per-line quote model hands those lines to the walk as config, and the two
# consequences are opposite halves of one defect: a payload naming AdvSendAdvert
# silences the warning this interface needs, and an unbalanced brace in the
# continuation corrupts brace depth and mutes every sibling block after it.
setup
printf 'interface eth0 {\n  AdvCaptivePortalAPI "\nAdvSendAdvert\non\n";\n  AdvRASrcAddress { fe80::1; };\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="no enabled AdvSendAdvert on directive found' \
  && ok "AdvSendAdvert on wrapped across lines inside a quoted value does not satisfy the gate" \
  || no "wrapped quoted payload" "rc=$_rc, log: $(cat "$LOG")"

setup
printf 'interface eth0 {\n  AdvCaptivePortalAPI "\n  {\n  ";\n  AdvSendAdvert on;\n  AdvRASrcAddress { fe80::1; };\n};\ninterface eth1 {\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'iface="eth1"' && ! logged 'iface="eth0"' \
  && ok "an unbalanced brace inside a wrapped quoted value masks no sibling interface block" \
  || no "brace in a wrapped quoted value" "rc=$_rc, log: $(cat "$LOG")"

report
