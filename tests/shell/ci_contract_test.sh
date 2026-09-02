#!/usr/bin/env bash
# The required Smoke check must run scripts/smoke.sh against its built image, and the Dockerfile must preserve its test-stage and package-refresh edges.
# SC2015: lib.sh verdict helpers return 0. SC2016: the literal ${...} and backticked
# strings ARE the assertion subjects -- they are patterns read out of the tree, not
# expressions to expand.
# shellcheck disable=SC2015,SC2016
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
WORKFLOW="$WORKFLOW_DIR/smoke.yml"
DOCKERFILE="$REPO_ROOT/Dockerfile"

if [ ! -d "$WORKFLOW_DIR" ]; then
  skip "the Smoke workflow still runs scripts/smoke.sh against the image it builds" ".github/workflows is absent (the image build does not copy it)"
  report
  exit
fi

if [ ! -f "$WORKFLOW" ]; then
  no "smoke workflow present" "$WORKFLOW is missing: the required Smoke check cannot run scripts/smoke.sh"
  report
  exit
fi

# Reject empty tags before comparing the build and smoke steps.
build_tag=$(sed -n 's/.*docker build .*-t[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' "$WORKFLOW" | head -n 1)
smoke_tag=$(sed -n 's|.*scripts/smoke\.sh[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*|\1|p' "$WORKFLOW" | head -n 1)

[ -n "$smoke_tag" ] \
  && ok "the Smoke workflow still has a step running scripts/smoke.sh against an image" \
  || no "smoke step present" "no step in $WORKFLOW invokes scripts/smoke.sh; the required check would stay green with the signal contract unexercised"

[ -n "$build_tag" ] && [ -n "$smoke_tag" ] && [ "$build_tag" = "$smoke_tag" ] \
  && ok "the Smoke workflow runs scripts/smoke.sh against the tag its build step creates ($build_tag)" \
  || no "smoke tag agreement" "build step tags '$build_tag', smoke step runs against '$smoke_tag'"

last_stage=$(awk '
  toupper($1) == "FROM" {
    name = ""
    for (i = 1; i < NF; i++) {
      if (toupper($i) == "AS") { name = $(i + 1) }
    }
  }
  END { print name }
' "$DOCKERFILE")
marker_edges=$(awk '
  toupper($1) == "FROM" {
    in_final = 0
    for (i = 1; i < NF; i++) {
      if (toupper($i) == "AS" && tolower($(i + 1)) == "final") { in_final = 1 }
    }
    next
  }
  in_final && toupper($1) == "COPY" && $0 ~ /--from=test([[:space:]]|$)/ { edges++ }
  END { print edges + 0 }
' "$DOCKERFILE")
[ "$last_stage" = "final" ] && [ "$marker_edges" -ge 1 ] \
  && ok "the default Docker target is final and final depends on the test stage" \
  || no "default build reaches tests" "last stage='$last_stage', final COPY --from=test edges=$marker_edges"

base_stage=$(awk '
  toupper($1) == "FROM" {
    if (in_base) { exit }
    in_base = 0
    for (i = 1; i < NF; i++) {
      if (toupper($i) == "AS" && tolower($(i + 1)) == "base") { in_base = 1 }
    }
  }
  in_base { print }
' "$DOCKERFILE")
upgrade_run=$(printf '%s\n' "$base_stage" | awk '
  function flush() {
    if (instruction ~ /apk upgrade --no-cache/) { print instruction }
    instruction = ""
  }
  /^[A-Z][A-Z]*[[:space:]]/ {
    flush()
    instruction = $0
    next
  }
  instruction != "" { instruction = instruction " " $0 }
  END { flush() }
')
printf '%s\n' "$base_stage" | grep -q '^ARG PKG_REFRESH=' \
  && [ -n "$upgrade_run" ] \
  && printf '%s\n' "$upgrade_run" | grep -Fq '${PKG_REFRESH}' \
  && ok "the base-stage apk upgrade RUN consumes PKG_REFRESH for its cache key" \
  || no "package refresh cache key" 'base-stage ARG or same-RUN ${PKG_REFRESH} expansion is missing'

COMPOSE="$REPO_ROOT/compose.yaml"
README="$REPO_ROOT/README.md"
compose_restart=$(awk '
  /^  [[:alnum:]_-]+:[[:space:]]*$/ { in_radvd = ($1 == "radvd:") }
  in_radvd && $1 == "restart:" { print $2; exit }
' "$COMPOSE" 2>/dev/null)
reload_section=$(sed -n '/^## Reloading configuration$/,/^## /p' "$README")
reload_command=$(printf '%s\n' "$reload_section" \
  | grep -E '^docker (kill -s HUP|restart) radvd$' | head -n 1)

# Asserted for every README shape: the caveat is the published consequence of a
# Docker behaviour that holds whichever command the section leads with.
printf '%s\n' "$reload_section" | grep -Fq 'prefer `docker restart` where it matters' \
  && printf '%s\n' "$reload_section" \
  | grep -Fq '`unless-stopped` is disarmed by the kill regardless' \
  && ok "the reload section keeps both published docker-kill restart-policy caveats" \
  || no "restart-policy caveat" "a published caveat phrase is missing from the Reloading section"

# compose.yaml is not copied into the image test stage, so this assertion states its
# own input instead of resting on the workflow guard at :15-19 exiting first. The two
# phrase checks above need no guard: README.md IS copied.
if [ ! -f "$COMPOSE" ]; then
  skip "the published reload procedure leads with the command that preserves restart-policy recovery" "compose.yaml is absent (the image build does not copy it)"
elif [ "$reload_command" = "docker restart radvd" ]; then
  ok "the published reload procedure leads with the command that preserves restart-policy recovery"
elif [ "$reload_command" = "docker kill -s HUP radvd" ] && [ "$compose_restart" = "unless-stopped" ]; then
  ok "the published reload procedure leads with the HUP form, whose consequence the caveat states"
else
  no "reload/restart-policy contract" "compose restart='$compose_restart', published reload='$reload_command'"
fi

report
