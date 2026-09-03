#!/usr/bin/env bash
# SC2015: lib.sh verdict helpers return 0. SC2034/SC2016: extracted child inputs.
# shellcheck disable=SC2015,SC2034,SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

load_function check_config_node
load_function sanitize_log_value
# The bounded child sources these extracted dependencies.
SRC=$(extract_function check_config_node "$WORK/check_config_node.sh") || exit 1
SANITIZER=$(extract_function sanitize_log_value "$WORK/sanitize_log_value.sh") || exit 1

LOG="$WORK/log"

setup() {
  DIR=$(mktemp -d "$WORK/conf.XXXXXX")
  CONF="$DIR/radvd.conf"
}

# `timeout` needs a command, so source the extracted functions in a child.
run_check() {
  _rc=0
  timeout 5 bash -c '
    set -u
    . "$1"
    . "$2"
    CONF=$3
    check_config_node
  ' _ "$SANITIZER" "$SRC" "$CONF" 2>"$LOG" || _rc=$?
}

logged() {
  grep -Fq "$1" "$LOG"
}

warn_count() {
  grep -c 'level=warn' "$LOG"
}

# Match the specific alert rule so drift on either side fails.
UNVERIFIED_RULE=$(sed -n '/alert: RadvdAdvertisementsUnverified/,/^        for:/p' "$REPO_ROOT/README.md" \
  | sed -n 's/^[[:space:]]*|~ `\(.*\)` \[[0-9]\+[a-z]\+\]$/\1/p')

alert_matched() {
  [ -n "$UNVERIFIED_RULE" ] && grep -Eq "$UNVERIFIED_RULE" "$LOG"
}

# --- 1. a non-regular config node is REFUSED, and PID 1 must not hang -----------
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
  && ! logged 'msg="radvd.conf could not be read' \
  && ok "a FIFO at radvd.conf is refused with exit 1 on one line, without hanging or misdiagnosing" \
  || no "FIFO refused" "rc=$_rc, log: $(cat "$LOG")"

# An ABSENT config is not a refusal: the reload call site has no readability gate,
# so the `-e` half of the probe is what keeps a config removed since startup on
# the unreadable-node path instead of exiting 1 after radvd has already been stopped.
setup
rm -f "$CONF"
run_check
[ "$_rc" -eq 0 ] && logged 'msg="radvd.conf could not be read' \
  && ! logged 'msg="radvd.conf is not a regular file' \
  && ok "an absent radvd.conf degrades instead of being refused as non-regular" \
  || no "absent config degraded" "rc=$_rc, log: $(cat "$LOG")"

alert_matched \
  && ok "the unreadable node warning matches the README's RadvdAdvertisementsUnverified pattern" \
  || no "alert contract (unreadable node)" "rule='$UNVERIFIED_RULE', log: $(cat "$LOG")"

# The unreadable-file arm of the same guard reaches the READ, not the -f probe —
# but root reads a chmod-000 file, so the branch cannot be provoked as root and
# asserting it would fail for a root maintainer while passing in CI.
setup
printf 'interface eth0 { IgnoreIfMissing on; AdvRASrcAddress { fe80::1; }; };\n' >"$CONF"
if [ "$(id -u)" -eq 0 ]; then
  skip "an unreadable radvd.conf routes to the unreadable-node warning" "root reads a chmod-000 file, so the refusal is unreachable"
else
  chmod 000 "$CONF"
  run_check
  [ "$_rc" -eq 0 ] && logged 'msg="radvd.conf could not be read' \
    && logged 'Permission denied' \
    && ok "an unreadable radvd.conf degrades via the failed read instead of misdiagnosing" \
    || no "unreadable degraded" "rc=$_rc, log: $(cat "$LOG")"
  chmod 644 "$CONF"
fi

report
