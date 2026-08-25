#!/usr/bin/env bash
# The startup config triage: the inline if/elif/else that decides between "run the
# HA validation", "warn and let radvd report it", and the boot's ONLY fatal
# (readable check failed on an existing file).
#
# This is inline boot code, not a function, so it comes out via extract_range and
# runs in a subshell per case with check_ha_directives stubbed to a recorder — the
# validator itself has its own test file, and what THIS block owes is the routing:
# which configs reach the validator, which warn, which abort.
#
# Lint directives, each against a stated guarantee rather than an assumption:
#   SC2015 - the `cond && ok || no` form cannot mis-fire, because lib.sh's
#     ok/no/skip return 0 unconditionally by design (see their comments).
#   SC2034 - CONF is the INPUT the extracted block reads at runtime; shellcheck
#     cannot see the read because the source happens inside run_triage.
#   SC2016 - the extract_range start pattern and run_triage's bash -c script are
#     single-quoted BECAUSE nothing may expand here: the pattern matches the
#     literal `"$CONF"` in the source, and $1/$2 are the subshell's positionals.
# shellcheck disable=SC2015,SC2034,SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The block is `if [ -r "$CONF" ]...fi` — the first column-0 fi closes it.
TRIAGE=$(extract_range '^if \[ -r "\$CONF" \]; then$' '^fi$' "$WORK/triage.sh") || exit 1

LOG="$WORK/log"

setup() {
  DIR=$(mktemp -d "$WORK/conf.XXXXXX")
  CONF="$DIR/radvd.conf"
}

# Each case runs the block in its own subshell: `exit 1` must reach a process
# boundary here, not this file, and the check_ha_directives stub records instead
# of validating.
run_triage() {
  _rc=0
  bash -c '
    set -u
    CONF=$1
    check_ha_directives() { printf "HA_CHECK_CALLED\n" >&2; }
    . "$2"
  ' _ "$CONF" "$TRIAGE" 2>"$LOG" || _rc=$?
}

logged() {
  grep -Fq "$1" "$LOG"
}

# The README's RadvdConfigError alert rule is an exact-string contract between the
# entrypoint's fatal lines and an operator's Loki rule, so read BOTH sides: pull the
# rule's own `|~` pattern out of the README and match the captured output against it
# as the regex Loki will use. Scoped to this one rule rather than grepping the file,
# because a file-wide match can pass against a pattern that has drifted onto another
# line; an empty extraction fails the assertions below rather than matching silently.
ALERT_RULE=$(sed -n '/alert: RadvdConfigError/,/^        for:/p' "$REPO_ROOT/README.md" \
  | sed -n 's/^[[:space:]]*|~ `\(.*\)` \[[0-9]\+[a-z]\]$/\1/p')

# --- 1. a readable, non-empty config routes to the HA validation ------------------
setup
printf 'interface eth0 { IgnoreIfMissing on; };\n' >"$CONF"
run_triage
[ "$_rc" -eq 0 ] && logged 'HA_CHECK_CALLED' && ! logged 'level=warn' \
  && ok "a readable config runs the HA validation and nothing else" \
  || no "readable config routing" "rc=$_rc, log: $(cat "$LOG")"

# --- 2. an EMPTY config warns (radvd will exit: no interface configured) ----------
# The warn and the validation both run: emptiness is a foretold radvd failure, not
# a reason to skip the HA-directive scan.
setup
: >"$CONF"
run_triage
[ "$_rc" -eq 0 ] && logged 'msg="radvd.conf is empty' && logged 'HA_CHECK_CALLED' \
  && ok "an empty config warns that radvd will exit, and still runs the validation" \
  || no "empty config warn" "rc=$_rc, log: $(cat "$LOG")"

# --- 3. an ABSENT config warns and skips the validation ---------------------------
# radvd reports the missing file with its own clear error; the entrypoint's job is
# only to say so up front. Nothing to validate.
setup
run_triage
[ "$_rc" -eq 0 ] && logged 'msg="radvd.conf not found' && ! logged 'HA_CHECK_CALLED' \
  && ok "an absent config warns and does not attempt validation" \
  || no "absent config warn" "rc=$_rc, log: $(cat "$LOG")"

# --- 4. the boot's ONLY fatal: the config exists but cannot be read ---------------
# Warn-and-continue would boot a radvd that exits on the same unreadable file with
# a less actionable error; the entrypoint names the real cause and refuses. Root
# reads through any file mode, so the branch is unreachable as root — a hard
# assertion here would fail for a root maintainer while passing in CI.
setup
printf 'interface eth0 { IgnoreIfMissing on; };\n' >"$CONF"
if [ "$(id -u)" -eq 0 ]; then
  skip "an existing but unreadable config aborts boot (exit 1) and matches the README's alert rule" "root reads a chmod-000 file, so the refusal is unreachable"
else
  chmod 000 "$CONF"
  run_triage
  [ "$_rc" -eq 1 ] && logged 'msg="radvd.conf exists but is not readable' && ! logged 'HA_CHECK_CALLED' \
    && ok "an existing but unreadable config aborts boot with exit 1 and the error names it" \
    || no "unreadable config fatal" "rc=$_rc, log: $(cat "$LOG")"
  [ -n "$ALERT_RULE" ] && grep -Eq "$ALERT_RULE" "$LOG" \
    && ok "the unreadable-config fatal line matches the README's RadvdConfigError alert pattern" \
    || no "alert contract (unreadable config)" "rule='$ALERT_RULE', log: $(cat "$LOG")"
  chmod 644 "$CONF"
fi

# --- 5. the third fatal's phrase is asserted at the SOURCE -------------------------
# `failed to create radvd PID directory` is the one alternative in the README's alert
# rule that no unit path drives (the mkdir only fails on a read-only /run), so this
# is a source-side check: the shipped script must still emit the phrase the rule
# matches. Rewording one side without the other silently stops the operator's alert.
[ -n "$ALERT_RULE" ] && grep -q 'printf .*failed to create radvd PID directory' "$ENTRYPOINT" \
  && printf 'failed to create radvd PID directory\n' | grep -Eq "$ALERT_RULE" \
  && ok "the PID-directory fatal phrase is emitted by the shipped script and matched by the alert rule" \
  || no "alert contract (PID directory, source-side)" "rule='$ALERT_RULE'"

report
