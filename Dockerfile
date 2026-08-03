# check=error=true

# renovate: datasource=github-tags depName=radvd-project/radvd
ARG RADVD_VERSION=v2.21
# github-tags exposes the git sha, not the tarball hash, so the marker below
# drives the repin postUpgradeTask, which recomputes this SHA256 in the same
# commit as a RADVD_VERSION bump. Upstream publishes the same hash as
# radvd-<N>.tar.gz.sha256 next to the release asset — cross-check against it.
# repin: dep=radvd-project/radvd url=https://github.com/radvd-project/radvd/releases/download/{version}/radvd-{version_nov}.tar.gz
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
# Embedded SBOM fragment. Syft inventories the final image from Alpine's APK
# database only, so the source-built payload (/usr/sbin/radvd + radvdump) is
# invisible to the signed release SBOM and to vulnerability scanners.
# Generate a CycloneDX fragment from the same Renovate-tracked version ARG
# the build uses — a Renovate bump keeps the SBOM correct with zero extra
# maintenance — and ship it in the runtime image (see the COPY in the runtime
# stage), where the release pipeline's centrally enabled Syft sbom-cataloger
# picks it up (cplieger/ci wiring; no per-repo .syft.yaml).
# CPE: the NVD CPE dictionary carries exactly one vendor:product for radvd —
# radvd.litech:radvd (non-deprecated, exact 2.21 entry, refs pointing at
# github.com/radvd-project/radvd); the sometimes-guessed
# litech:router_advertisement_daemon has no dictionary entry at all.
# ---------------------------------------------------------------------------
RUN cat > /out/radvd.cdx.json <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "components": [
    {
      "bom-ref": "pkg:github/radvd-project/radvd@${RADVD_VERSION}",
      "type": "application",
      "name": "radvd",
      "version": "${RADVD_VERSION#v}",
      "purl": "pkg:github/radvd-project/radvd@${RADVD_VERSION}",
      "cpe": "cpe:2.3:a:radvd.litech:radvd:${RADVD_VERSION#v}:*:*:*:*:*:*:*"
    }
  ]
}
EOF

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
RUN addgroup -S radvd && adduser -S -D -H -G radvd radvd

COPY --from=builder /out/usr/sbin/ /usr/sbin/
# CycloneDX SBOM fragment for the source-built radvd (generated in the
# builder stage from the Renovate-tracked version ARG). Placed where the
# release pipeline's Syft sbom-cataloger inventories it, so SBOMs and
# scanners see radvd alongside the APK packages.
COPY --from=builder /out/radvd.cdx.json /usr/share/sbom/radvd.cdx.json
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# ---------------------------------------------------------------------------
# Test stage — runs the build-time smoke test (binary runs + configtest
# accepts a valid config and rejects a malformed one, plus the built binary
# and the embedded SBOM fragment both report exactly the pinned
# RADVD_VERSION). A failure here fails the
# centralized `ci / validate` docker build gate, because the final stage
# below depends on this stage's marker.
# ---------------------------------------------------------------------------
FROM base AS test
ARG RADVD_VERSION
COPY tests/ /tmp/tests/
# ${RADVD_VERSION:?} fails the build if the ARG wiring ever breaks, so the
# smoke test's exact-version assertion can never be skipped in-image (the
# leading v is stripped inside smoke.sh).
RUN RADVD_EXPECTED_VERSION="${RADVD_VERSION:?}" sh /tmp/tests/smoke.sh && touch /tests-passed

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
    CMD ["pidof", "radvd"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
