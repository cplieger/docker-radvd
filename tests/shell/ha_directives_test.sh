#!/usr/bin/env bash
# check_ha_directives(): the 118-line validator behind the HA warnings.
#
# Everything here is warn-only by design (a single-node operator legitimately
# deploys without HA), so what a test pins is WHICH warning fires for which config
# shape — and, just as load-bearing, which shapes stay SILENT. A false warning
# against a valid config is how a real one gets ignored.
#
# The function's only input is the CONF global (entrypoint.sh assigns it plainly,
# never readonly); it derives CONF_DIR itself. Every case builds a fresh config
# dir and points CONF into it. No stubs: dirname, sed, grep, awk, cat, tr and cut
# run for real against fixture files.
#
# DIALECT NOTE: the shipped file is #!/bin/sh under BusyBox ash with BusyBox
# sed/grep/awk in the image; this suite runs it under bash with the runner's own
# awk (mawk on this container) and GNU sed/grep/tr. The comparison is therefore
# host-tool-vs-BusyBox, not GNU-vs-BusyBox, and it is NOT a compatibility gate:
# the assertions stay POSIX-shaped and assert OUTCOMES (which warning line,
# silence, one parseable line), never a tool-specific substitution. The one place
# the dialects are known to diverge is the sanitizer path (BusyBox tr v1.37.0 has
# no [:print:], which is why the shipped code deletes [:cntrl:] instead), so those
# cases assert the resulting log line's shape rather than the exact bytes.
#
# Lint directives, each against a stated guarantee rather than an assumption:
#   SC2015 - the `cond && ok || no` form cannot mis-fire, because lib.sh's
#     ok/no/skip return 0 unconditionally by design (see their comments).
#   SC2034 - CONF is the INPUT the extracted code reads at runtime; shellcheck
#     cannot see that read because the source happens through load_function.
#   SC2016 - run_check's bash -c script is single-quoted BECAUSE nothing may
#     expand in this shell: $1/$2 are the subshell's own positionals.
# shellcheck disable=SC2015,SC2034,SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

load_function check_ha_directives
# The same extraction, kept as a file for run_check's bounded subshell below.
SRC=$(extract_function check_ha_directives "$WORK/check_ha_directives.sh") || exit 1

LOG="$WORK/log"

setup() {
  DIR=$(mktemp -d "$WORK/conf.XXXXXX")
  CONF="$DIR/radvd.conf"
}

# The validator can block forever if its non-regular-file guard is gone (the cat
# probe would read a FIFO to EOF that never comes), so every run is bounded: a
# hang becomes a non-zero status here instead of a wedged test run. `timeout`
# needs a COMMAND, not a shell function, hence the bash -c re-entry sourcing the
# already-extracted file.
run_check() {
  _rc=0
  timeout 5 bash -c '
    set -u
    . "$1"
    CONF=$2
    check_ha_directives
  ' _ "$SRC" "$CONF" 2>"$LOG" || _rc=$?
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
printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && [ ! -s "$LOG" ] \
  && ok "a valid one-line nested config is silent (mid-line directives found)" \
  || no "one-line config" "rc=$_rc, log: $(cat "$LOG")"

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

# --- 8. THE CLASSIC HA MISTAKE: AdvRASrcAddress on a global/ULA address -----------
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
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { 2001:db8::5; };\n};\n' >"$CONF"
run_check
logged 'msg="AdvRASrcAddress is set to a non-link-local address' && logged '2001:db8::5' \
  && ok "a GUA AdvRASrcAddress warns as non-link-local" \
  || no "GUA source warned" "log: $(cat "$LOG")"

# --- 9. a correct block must not MASK a broken sibling ----------------------------
# Across files: eth0's correct block in a.conf, the global-VIP mistake in b.conf.
# The warning has to name the offending file, or a multi-file operator re-greps by
# hand.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fe80::1; };\n};\n' >"$DIR/a.conf"
printf 'interface eth1 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fd00::78; };\n};\n' >"$DIR/b.conf"
run_check
logged 'msg="AdvRASrcAddress is set to a non-link-local address' && logged 'b.conf:fd00::78' \
  && ok "a broken sibling FILE is not masked by a correct one, and is named file:address" \
  || no "cross-file sibling" "log: $(cat "$LOG")"

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

# --- 12. an unscannable config degrades to ONE warning, and PID 1 must not hang ---
# A FIFO matching *.conf: without the regular-file probe the cat probe reads it to
# an EOF that never comes, wedging boot (and every HUP reload) with no log line.
# run_check's timeout turns that hang into a failure here.
setup
printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$CONF"
mkfifo "$DIR/pipe.conf"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="unable to scan mounted radvd config' \
  && [ "$(warn_count)" -eq 1 ] && ! logged 'no enabled IgnoreIfMissing' \
  && ok "a FIFO in the mount degrades to one scan warning, without hanging or misdiagnosing" \
  || no "FIFO degraded" "rc=$_rc, log: $(cat "$LOG")"

# A subdirectory matching *.conf — the root-safe shape of the same guard.
setup
printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$CONF"
mkdir "$DIR/sub.conf"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="unable to scan mounted radvd config' && [ "$(warn_count)" -eq 1 ] \
  && ok "a directory named *.conf degrades to one scan warning instead of a misleading one" \
  || no "dir degraded" "rc=$_rc, log: $(cat "$LOG")"

# An empty config dir: the unmatched glob stays literal, fails -f, same guard.
setup
rm -f "$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="unable to scan mounted radvd config' \
  && ok "an empty config dir (unmatched glob) degrades to the scan warning" \
  || no "unmatched glob" "rc=$_rc, log: $(cat "$LOG")"

# The unreadable-file arm of the same guard reaches the CAT probe, not the -f
# probe — but root reads a chmod-000 file, so the branch cannot be provoked as
# root and asserting it would fail for a root maintainer while passing in CI.
setup
printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$CONF"
if [ "$(id -u)" -eq 0 ]; then
  skip "unreadable *.conf routes to the cat-probe warning" "root reads a chmod-000 file, so the refusal is unreachable"
else
  chmod 000 "$CONF"
  run_check
  [ "$_rc" -eq 0 ] && logged 'msg="unable to scan mounted radvd config' \
    && ok "an unreadable *.conf degrades via the cat probe instead of misdiagnosing" \
    || no "unreadable degraded" "rc=$_rc, log: $(cat "$LOG")"
  chmod 644 "$CONF"
fi

# --- 13. the degraded warning survives a hostile filename -------------------------
# Two properties, and the second needs bait a quote cannot supply: the quote is
# neutralized (to ? — the awk clean() convention), and an embedded NEWLINE cannot
# forge a second structured-log line. A quote-only fixture leaves the
# control-character filter unexercised, so a name carrying both is the bait.
# The oracle is the SUBSTITUTED form, positively: the newline is DELETED by
# `tr -d [:cntrl:]` and the quotes MAPPED to `?`, so the sanitized name collapses to
# one predictable token. A negative "no quote anywhere" test cannot work here -- the
# log line's own err="/path=" delimiters are quotes -- and asserting only the absence
# of the forged fragment left the case unable to fail (the raw literal cannot appear
# whether the filters run or not).
setup
printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$CONF"
_hostile=$(printf 'x"\nlevel=error msg="forged.conf')
mkdir "$DIR/$_hostile"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="unable to scan mounted radvd config' \
  && [ "$(wc -l <"$LOG")" -eq 1 ] \
  && grep -Fq 'x?level=error msg=?forged.conf' "$LOG" \
  && ok "a quote and an embedded newline in a filename are neutralized; the warning stays one line" \
  || no "sanitizer outcome" "lines=$(wc -l <"$LOG"), log: $(cat "$LOG")"

# --- 14. the awk scanner's own clean() reaches hostile data ------------------------
# Everything above routes through warn_scan_degraded; the awk scanner has a SECOND
# sanitizer for the bad= field, applied to BOTH the filename and the address token,
# and no case reached it -- every hostile-name fixture so far was a directory, which
# returns at the regular-file probe before awk ever runs. These two cases reach it,
# one per call site, because clean() around the filename and clean() around the
# token are independently deletable.
setup
rm -f "$CONF"
_hostile_conf="$DIR/$(printf 'bad".conf')"
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fd00::78; };\n};\n' >"$_hostile_conf"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="AdvRASrcAddress is set to a non-link-local address' \
  && [ "$(wc -l <"$LOG")" -eq 1 ] && ! grep -Fq 'bad".conf' "$LOG" \
  && grep -q 'bad?.conf' "$LOG" \
  && ok "the awk scanner neutralizes a quote in the offending FILENAME it names in bad=" \
  || no "awk clean() on FILENAME" "lines=$(wc -l <"$LOG"), log: $(cat "$LOG")"

# The ADDRESS TOKEN half: a quote inside the address survives tokenization (the
# splitter cuts on ';' and trims only space/tab), so it reaches bad= as part of the
# token and clean() is the only thing standing between it and the log line.
setup
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fd00::"78; };\n};\n' >"$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="AdvRASrcAddress is set to a non-link-local address' \
  && [ "$(wc -l <"$LOG")" -eq 1 ] && ! grep -Fq 'fd00::"78' "$LOG" \
  && grep -q 'fd00::?78' "$LOG" \
  && ok "the awk scanner neutralizes a quote inside the ADDRESS token it names in bad=" \
  || no "awk clean() on the address token" "lines=$(wc -l <"$LOG"), log: $(cat "$LOG")"

# The control-character arm of the SAME clean(), which the quote mapping cannot
# cover: a filename carrying an embedded newline, as a real readable *.conf this
# time (it still ends in .conf, so it passes -f and reaches awk rather than
# short-circuiting into warn_scan_degraded). The one-line oracle is what the cntrl
# substitution holds together.
setup
rm -f "$CONF"
_cntrl_conf="$DIR/$(printf 'x\nlevel=error msg="forged.conf')"
printf 'interface eth0 {\n  IgnoreIfMissing on;\n  AdvRASrcAddress { fd00::78; };\n};\n' >"$_cntrl_conf"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="AdvRASrcAddress is set to a non-link-local address' \
  && [ "$(wc -l <"$LOG")" -eq 1 ] && ! grep -Fq 'msg="forged' "$LOG" \
  && ok "an embedded newline in a scanned filename cannot forge a second bad= log line" \
  || no "awk clean() control-character arm" "lines=$(wc -l <"$LOG"), log: $(cat "$LOG")"

report
