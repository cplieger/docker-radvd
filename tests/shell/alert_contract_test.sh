#!/usr/bin/env bash
# The alert contract lives outside ci_contract_test.sh because that file skips when
# the image build stage has no .github directory.
# SC2016: the backticked README pattern is the literal extraction subject.
# shellcheck disable=SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# Derive the set because alert rules can be added or removed without updating this test.
patterns=$(sed -n 's/^[[:space:]]*|~ `\(.*\)` \[[0-9]\+[a-z]\]$/\1/p' "$REPO_ROOT/README.md")
published_count=$(grep -c '^      - alert:' "$REPO_ROOT/README.md" || true)
pattern_count=$(printf '%s\n' "$patterns" | grep -c . || true)
union=$(printf '%s\n' "$patterns" | tr '\n' '|')
union=${union%|}

rule_set_valid=1
if [ -z "$patterns" ] || [ "$pattern_count" -ne "$published_count" ]; then
  no "published alert pattern extraction" "patterns=$pattern_count, alerts=$published_count"
  rule_set_valid=0
fi
case "$union" in
  '' | '|'* | *'||'* | *'|')
    no "published alert pattern union" "invalid union shape: '$union'"
    rule_set_valid=0
    ;;
  *)
    ok "the published alert patterns form a non-empty ERE without an empty alternative"
    ;;
esac

emitters=$(awk '
  /printf .level=(error|warn) msg="/ {
    marker = "msg=\""
    start = index($0, marker)
    message = substr($0, start + length(marker))
    stop = index(message, "\"")
    if (start && stop) print substr(message, 1, stop - 1)
  }
' "$ENTRYPOINT")
extracted_emitter_count=$(printf '%s\n' "$emitters" | grep -c . || true)
printf_emitter_count=$(grep -cE 'printf .level=(error|warn) msg="' "$ENTRYPOINT" || true)
level_emitter_count=$(grep -cE 'level=(error|warn)' "$ENTRYPOINT" || true)
if [ "$extracted_emitter_count" -eq "$printf_emitter_count" ] \
  && [ "$printf_emitter_count" -eq "$level_emitter_count" ] \
  && [ "$extracted_emitter_count" -ne 0 ]; then
  ok "every entrypoint error and warning has an extracted message"
else
  no "entrypoint fault extraction" "extracted=$extracted_emitter_count, printf=$printf_emitter_count, level=$level_emitter_count"
  rule_set_valid=0
fi

# Error and warning records need operator action; info transitions stay outside this contract.
if [ "$rule_set_valid" -eq 1 ]; then
  unmatched=$(while IFS= read -r emitter; do
    if ! printf '%s\n' "$emitter" | grep -Eq -- "$union"; then
      printf '%s\n' "$emitter"
    fi
  done <<<"$emitters")
  if [ -z "$unmatched" ]; then
    ok "every entrypoint error and warning is selected by a published alert rule"
  else
    no "entrypoint fault alert coverage" "unmatched: $(printf '%s' "$unmatched" | tr '\n' '|')"
  fi
else
  no "entrypoint fault alert coverage" "the rule or emitter derivation is invalid"
fi

if [ -x /usr/sbin/radvd ]; then
  # Use binary rodata because adjacent C literals do not preserve the published source fragment.
  # Use full format strings so a shared substring cannot satisfy an unrelated binding.
  anchors=$(
    cat <<'EOF'
IPv6 forwarding seems to be disabled, but continuing anyway
IPv6 forwarding on interface seems to be disabled, but continuing anyway
received icmpv6 RA packet with non-linklocal source address
exiting, permissions on conf_file invalid
exiting, failed to read config file
%s not found: %s
interface %s does not exist or is not set up properly (setup_iface=%d)
unable to drop root privileges
MinRtrAdvInterval for %s (%.2f) must be at least %.2f but no more than 3/4 of MaxRtrAdvInterval (%.2f)
MaxRtrAdvInterval for %s (%.2f) must be between %.2f and %d
AdvLinkMTU for %s (%u) must be zero or between %u and %u
AdvReachableTime for %s (%u) must not be greater than %u
AdvHomeAgentFlag for %s must be set with HomeAgentInfo
AdvValidLifetime for %s (%u) must be greater than or equal to AdvPreferredLifetime for
invalid prefix length in %s, line %d
invalid route prefix length in %s, line %d
EOF
  )

  if [ "$rule_set_valid" -eq 1 ]; then
    binding_failures=$(while IFS= read -r anchor; do
      if ! grep -aFq "$anchor" /usr/sbin/radvd; then
        printf 'shipped binary missing anchor: %s\n' "$anchor"
      fi
      if ! printf '%s\n' "$anchor" | grep -Eq -- "$union"; then
        printf 'README patterns do not select anchor: %s\n' "$anchor"
      fi
    done <<<"$anchors")

    fault_lines=$(grep -E 'printf .level=(error|warn) msg="' "$ENTRYPOINT" || true)
    completeness_failures=$(printf '%s\n' "$union" | tr '|' '\n' | while IFS= read -r alternative; do
      if printf '%s\n' "$anchors" | grep -Eq -- "$alternative"; then
        continue
      fi
      if printf '%s\n' "$fault_lines" | grep -Eq -- "$alternative"; then
        continue
      fi
      printf 'published alternative has no binary or entrypoint binding: %s\n' "$alternative"
    done)

    upstream_failures="${binding_failures}${binding_failures:+$'\n'}${completeness_failures}"
    if [ -z "$upstream_failures" ]; then
      ok "every published upstream alert pattern is bound to the shipped radvd binary"
    else
      no "published upstream alert binding" "$(printf '%s' "$upstream_failures" | tr '\n' '|')"
    fi
  else
    no "published upstream alert binding" "the published rule derivation is invalid"
  fi
else
  skip "every published upstream alert pattern is bound to the shipped radvd binary" "/usr/sbin/radvd is absent outside the image build stage"
fi

report
