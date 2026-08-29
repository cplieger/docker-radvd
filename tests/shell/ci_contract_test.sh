#!/usr/bin/env bash
# The one repo-contract case in this suite: the Smoke workflow must still RUN
# scripts/smoke.sh against the image it builds. `Smoke / smoke` is a required check
# on main and that one step is the only thing in the job that runs anything against
# a container, so deleting or renaming it leaves the required check green with the
# supervisor's whole signal contract unexercised — the build-time test stage
# exercises no running container, and nothing else covers it. Both sides are read at
# run time: the tag is parsed out of the build step and out of the run step rather
# than hardcoded, so renaming it in one place and not the other is red here.
#
# It asserts the WIRING only: not the runner, not the checkout pinning, not the
# build args. Its home is `ci / validate`, which is the check that keeps reporting
# when the Smoke workflow stops asserting.
#
# Lint directives, each against a stated guarantee rather than an assumption:
#   SC2015 - `cond && ok || no` cannot mis-fire: lib.sh's ok/no/skip return 0.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
WORKFLOW="$WORKFLOW_DIR/smoke.yml"

# Gated on the DIRECTORY, not the file: the Dockerfile test stage copies tests/,
# README.md and CONTRIBUTING.md into /tmp and never .github/, so the whole
# directory is absent in the image build and present in a checkout. Gating on the
# file instead would make deleting or RENAMING smoke.yml a green skip, which is the
# silent decay this case exists to catch.
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

# One `docker build -t <tag>` and one `scripts/smoke.sh <tag>`; each parsed from the
# step that owns it. Both are asserted non-empty BEFORE they are compared, because
# an empty-equals-empty comparison passes vacuously.
build_tag=$(sed -n 's/.*docker build .*-t[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' "$WORKFLOW" | head -n 1)
smoke_tag=$(sed -n 's|.*scripts/smoke\.sh[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*|\1|p' "$WORKFLOW" | head -n 1)

[ -n "$smoke_tag" ] \
  && ok "the Smoke workflow still has a step running scripts/smoke.sh against an image" \
  || no "smoke step present" "no step in $WORKFLOW invokes scripts/smoke.sh; the required check would stay green with the signal contract unexercised"

[ -n "$build_tag" ] && [ -n "$smoke_tag" ] && [ "$build_tag" = "$smoke_tag" ] \
  && ok "the Smoke workflow runs scripts/smoke.sh against the tag its build step creates ($build_tag)" \
  || no "smoke tag agreement" "build step tags '$build_tag', smoke step runs against '$smoke_tag'"

report
