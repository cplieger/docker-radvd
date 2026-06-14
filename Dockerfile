# check=error=true

FROM alpine:3.24.0@sha256:a2d49ea686c2adfe3c992e47dc3b5e7fa6e6b5055609400dc2acaeb241c829f4 AS base

# No apk version pin: the digest-pinned base above fixes the apk index, so the
# radvd version is already reproducible per base digest and floats forward on a
# base bump instead of stranding on an Alpine release change.
# apk upgrade first: the pinned base ships some packages (e.g. libssl3) stale;
# upgrading floats them forward on each rebuild.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
        radvd
RUN grep -q '^radvd:' /etc/group || addgroup -S radvd; \
    grep -q '^radvd:' /etc/passwd || adduser -S -D -H -G radvd radvd

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# ---------------------------------------------------------------------------
# Test stage — runs the build-time smoke test (binary runs + configtest
# accepts a valid config and rejects a malformed one). A failure here fails
# the centralized `ci / validate` docker build gate, because the final stage
# below depends on this stage's marker.
# ---------------------------------------------------------------------------
FROM base AS test
COPY tests/ /tmp/tests/
RUN sh /tmp/tests/smoke.sh && touch /tests-passed

# ---------------------------------------------------------------------------
# Final stage — the runtime image. Must remain last so the CI build gate
# (which builds the default target) produces it; the marker COPY forces the
# test stage to build and pass first.
# ---------------------------------------------------------------------------
FROM base AS final
COPY --from=test /tests-passed /tests-passed

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof radvd >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
