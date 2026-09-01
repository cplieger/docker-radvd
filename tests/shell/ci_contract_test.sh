#!/usr/bin/env bash
# The required Smoke check must run scripts/smoke.sh against its built image.
# SC2015: lib.sh verdict helpers return 0.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
WORKFLOW="$WORKFLOW_DIR/smoke.yml"

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

report
