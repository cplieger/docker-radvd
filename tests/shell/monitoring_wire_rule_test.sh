#!/usr/bin/env bash
# The example CoreRAD rule in docs/monitoring.md is checked here, because the alert
# rule checks read only the files under alerts/.
# PROMTOOL names a local promtool binary; without it the pinned image runs promtool.
#
# SC2015: `cond && ok || no` cannot mis-fire, because lib.sh's ok/no return 0.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

page=$REPO_ROOT/docs/monitoring.md
image=prom/prometheus:v3.16.0@sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06
rule=$WORK/wire.yaml
section="## Checking advertisements continuously"

if [ ! -f "$page" ]; then
  skip "the example wire rule passes promtool" "docs/monitoring.md is absent (the image build does not copy it)"
  report
  exit
fi

# The image runs promtool as an unprivileged user, which must read the rule file.
chmod 755 "$WORK"
awk -v section="$section" '
  /^## / { in_section = ($0 == section); next }
  in_section && !done && /^```yaml$/ { in_block = 1; next }
  in_block && /^```$/ { in_block = 0; done = 1; next }
  in_block { print }
' "$page" >"$rule"
chmod 644 "$rule"

if [ ! -s "$rule" ]; then
  no "example rule extraction" "docs/monitoring.md has no yaml block under \"$section\""
  report
  exit
fi
ok "docs/monitoring.md shows a yaml example under Checking advertisements continuously"

series='corerad_monitor_messages_received_total{message="router advertisement", host="[^"]*"}'
# CoreRAD creates the series only when an advertisement arrives, so after a monitor
# restart it is missing until the next one. The uptime guard and absent_over_time keep
# a restart from paging; plain absent() would fire until radvd's next advertisement.
grep -q "increase($series\[[0-9]*m\]) == 0" "$rule" \
  && grep -Eq '^ *and on\(instance, job\) \(time\(\) - process_start_time_seconds\) > [0-9]+$' "$rule" \
  && ok "the example rule fires when a known router's advertisements stop, once the monitor has run a full window" \
  || no "stopped-advertisements arm" "no increase(${series}[<n>m]) == 0 guarded by and on(instance, job) (time() - process_start_time_seconds) > <s>"
grep -q "absent_over_time($series\[[0-9]*m\])" "$rule" \
  && ! grep -q "absent($series)" "$rule" \
  && ok "the example rule fires when no advertisement from the router reached the monitor in the window" \
  || no "absent arm" "no absent_over_time(${series}[<n>m]), or a plain absent() that pages on every monitor restart"

if [ -n "${PROMTOOL:-}" ]; then
  "$PROMTOOL" check rules "$rule" >"$WORK/promtool.out" 2>&1
  rc=$?
elif command -v docker >/dev/null 2>&1; then
  # Three pulls, so one registry timeout on a shared runner does not fail the rule check.
  for attempt in 1 2 3; do
    docker pull -q "$image" >/dev/null && break
    sleep $((attempt * 5))
  done
  docker run --rm --network none --entrypoint promtool -v "$WORK:/rules:ro" "$image" \
    check rules /rules/wire.yaml >"$WORK/promtool.out" 2>&1
  rc=$?
else
  printf 'set PROMTOOL to a promtool binary, or install Docker to run %s\n' "$image" >"$WORK/promtool.out"
  rc=127
fi
[ "$rc" -eq 0 ] \
  && ok "promtool check rules accepts the example rule" \
  || no "promtool check rules" "rc=$rc: $(cat "$WORK/promtool.out")"

report
