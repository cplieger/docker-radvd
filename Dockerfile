# check=error=true

# renovate: datasource=github-tags depName=radvd-project/radvd
ARG RADVD_VERSION=v2.21
# When RADVD_VERSION is bumped, update this SHA256 to match the new dist
# tarball. Renovate can't recompute it (github-tags exposes the git sha, not
# the tarball hash), so it labels the bump PR `manual-sha-bump` and puts this
# command in the PR body — run it, paste the result here, push:
# curl -sL https://github.com/radvd-project/radvd/releases/download/v<N>/radvd-<N>.tar.gz | sha256sum
# Upstream publishes the same hash as radvd-<N>.tar.gz.sha256 next to the
# release asset — cross-check against it.
ARG RADVD_SHA256=09e5cf7712397463fd35ebca71f3c05f7d31cff9246513f12d03a359c40b089c

# ---------------------------------------------------------------------------
# Builder stage — compiles radvd from the pinned upstream release tarball.
# Discarded at the end of the build; only the stripped binaries reach the
# runtime image below.
# ---------------------------------------------------------------------------
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Build deps are build-only (discarded with this stage, absent from the
# runtime image), so their exact versions never reach the shipped artifact and
# are intentionally left unpinned — they track whatever the Alpine 3.24 repo
# serves at build time (the digest pins the base image, not the apk index).
# radvd itself stays version+SHA pinned below — it is the shipped artifact.
# Set mirrors Alpine's radvd APKBUILD makedepends minus what the dist tarball
# makes unnecessary: autoconf/automake (tarball ships a generated configure),
# libbsd-dev (musl provides strlcpy natively; configure only wants libbsd as a
# fallback), libdaemon-dev (unreferenced by radvd 2.21's configure), check-dev
# (unit-test harness only, not a feature of the shipped binary).
# hadolint ignore=DL3018
RUN apk add --no-cache bison build-base flex linux-headers pkgconf

ARG RADVD_VERSION
ARG RADVD_SHA256
WORKDIR /build/radvd
# Fetch the upstream dist tarball (stable release asset, NOT the auto-generated
# tag archive) and verify it fail-closed against the pinned SHA256 before
# extracting. Configure flags mirror the feature-relevant set from Alpine
# 3.24-stable's radvd APKBUILD: --with-pidfile keeps radvd writing its PID to
# /run/radvd/radvd.pid (the entrypoint creates that directory and radvd
# refuses to start without it), --sysconfdir keeps the compiled-in default
# config path at /etc/radvd.conf. `make gram.h` first works around the same
# parallel-build race the APKBUILD documents. Both sbin binaries (radvd +
# radvdump) are kept for parity with the Alpine package this build replaces.
RUN wget -q --tries=3 --timeout=30 \
      "https://github.com/radvd-project/radvd/releases/download/${RADVD_VERSION}/radvd-${RADVD_VERSION#v}.tar.gz" \
    && echo "${RADVD_SHA256}  radvd-${RADVD_VERSION#v}.tar.gz" | sha256sum -c - \
    && tar xzf "radvd-${RADVD_VERSION#v}.tar.gz" --strip-components=1 --no-same-owner \
    && rm "radvd-${RADVD_VERSION#v}.tar.gz" \
    && ./configure \
        --prefix=/usr \
        --sysconfdir=/etc/ \
        --with-pidfile=/run/radvd/radvd.pid \
    && make gram.h \
    && make -j"$(nproc)" \
    && strip radvd radvdump \
    && install -D -m 755 radvd /out/usr/sbin/radvd \
    && install -D -m 755 radvdump /out/usr/sbin/radvdump

# ---------------------------------------------------------------------------
# Runtime stage — same digest-pinned base as before the source-build
# conversion; only how radvd is obtained changed (COPY from the builder
# instead of installing the Alpine package). radvd links against nothing
# beyond musl (already in the base), so no runtime lib packages are added.
# ---------------------------------------------------------------------------
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS base

# apk upgrade: the pinned base ships some packages (e.g. libssl3) stale;
# upgrading floats them forward on each rebuild.
RUN apk upgrade --no-cache
RUN grep -q '^radvd:' /etc/group || addgroup -S radvd; \
    grep -q '^radvd:' /etc/passwd || adduser -S -D -H -G radvd radvd

COPY --from=builder /out/usr/sbin/ /usr/sbin/
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# ---------------------------------------------------------------------------
# Test stage — runs the build-time smoke test (binary runs + configtest
# accepts a valid config and rejects a malformed one, plus the built binary
# reports exactly the pinned RADVD_VERSION). A failure here fails the
# centralized `ci / validate` docker build gate, because the final stage
# below depends on this stage's marker.
# ---------------------------------------------------------------------------
FROM base AS test
ARG RADVD_VERSION
COPY tests/ /tmp/tests/
RUN RADVD_EXPECTED_VERSION="${RADVD_VERSION#v}" sh /tmp/tests/smoke.sh && touch /tests-passed

# ---------------------------------------------------------------------------
# Final stage — the runtime image. Must remain last so the CI build gate
# (which builds the default target) produces it; the marker COPY forces the
# test stage to build and pass first.
# ---------------------------------------------------------------------------
FROM base AS final
COPY --from=test /tests-passed /tests-passed

# Liveness only: healthy whenever the radvd process is alive. It cannot see the
# HA-backup 'running but emitting no RAs' state (missing source address); see the
# README 'Healthcheck' section for the off-host rdisc6 end-to-end probe.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof radvd >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
