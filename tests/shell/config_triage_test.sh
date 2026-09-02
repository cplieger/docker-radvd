#!/usr/bin/env bash
# Extracted triage exits in a child process.
# SC2015: lib.sh verdict helpers return 0. SC2034/SC2016: extracted child inputs.
# shellcheck disable=SC2015,SC2034,SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

TRIAGE=$(extract_range '^if \[ -r "\$CONF" \]; then$' '^fi$' "$WORK/triage.sh") || exit 1

LOG="$WORK/log"

setup() {
  DIR=$(mktemp -d "$WORK/conf.XXXXXX")
  CONF="$DIR/radvd.conf"
}

run_triage() {
  _rc=0
  bash -c '
    set -u
    CONF=$1
    check_config_node() { printf "NODE_CHECK_CALLED\n" >&2; }
    . "$2"
  ' _ "$CONF" "$TRIAGE" 2>"$LOG" || _rc=$?
}

logged() {
  grep -Fq "$1" "$LOG"
}

# Match the specific alert rule so drift on either side fails.
ALERT_RULE=$(sed -n '/alert: RadvdConfigError/,/^        for:/p' "$REPO_ROOT/README.md" \
  | sed -n 's/^[[:space:]]*|~ `\(.*\)` \[[0-9]\+[a-z]\]$/\1/p')

# --- 1. a readable, non-empty config routes to the node check ------------------
setup
printf 'interface eth0 { IgnoreIfMissing on; };\n' >"$CONF"
run_triage
[ "$_rc" -eq 0 ] && logged 'NODE_CHECK_CALLED' && ! logged 'level=warn' \
  && ok "a readable config runs the node check and nothing else" \
  || no "readable config routing" "rc=$_rc, log: $(cat "$LOG")"

# --- 2. the PID-directory fatal's phrase is asserted at the SOURCE -----------------
# `failed to create radvd PID directory` is the one alternative in the README's alert
# rule that no UNIT path drives (the mkdir only fails on a read-only /run);
# scripts/smoke.sh scenario 8 drives it at runtime, so this source-side check is the
# fast half of that pair: the shipped script must still emit the phrase the rule
# matches. Rewording one side without the other silently stops the operator's alert.
[ -n "$ALERT_RULE" ] && grep -q 'printf .*failed to create radvd PID directory' "$ENTRYPOINT" \
  && printf 'failed to create radvd PID directory\n' | grep -Eq "$ALERT_RULE" \
  && ok "the PID-directory fatal phrase is emitted by the shipped script and matched by the alert rule" \
  || no "alert contract (PID directory, source-side)" "rule='$ALERT_RULE'"

report
