# check=error=true

# renovate: datasource=github-tags depName=radvd-project/radvd
ARG RADVD_VERSION=v2.21
# github-tags exposes the git sha, not the tarball hash, which is why the repin
# marker below exists. Upstream publishes the same hash as radvd-<N>.tar.gz.sha256.
# repin: dep=radvd-project/radvd url=https://github.com/radvd-project/radvd/releases/download/{version}/radvd-{version_nov}.tar.gz
ARG RADVD_SHA256=09e5cf7712397463fd35ebca71f3c05f7d31cff9246513f12d03a359c40b089c

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# An apk version pin does not survive an Alpine base bump; the digest-pinned base is the reproducibility guarantee.
# The set omits what the dist tarball makes unnecessary: autoconf/automake (tarball
# ships a generated configure), libbsd-dev (musl provides strlcpy natively;
# configure only wants libbsd as a fallback), libdaemon-dev (unreferenced by
# radvd's configure), check-dev (unit-test harness only, not a shipped feature).
# hadolint ignore=DL3018
RUN apk add --no-cache bison build-base flex linux-headers pkgconf

ARG RADVD_VERSION
ARG RADVD_SHA256
WORKDIR /build/radvd
# Fetch the release ASSET, not the auto-generated tag archive; that is what makes a SHA pin stable. The CycloneDX
# fragment is emitted from this same RUN so the URL is spelled once: the bytes fetched, the digest verified and the
# published download_url cannot drift apart. Syft inventories the final image from Alpine's APK database only, so the
# source-built payload would otherwise be invisible to the signed release SBOM and to scanners. CPE: the NVD dictionary
# carries exactly one vendor:product for radvd — radvd.litech:radvd; the sometimes-guessed
# litech:router_advertisement_daemon has no dictionary entry at all. --with-pidfile keeps radvd writing its PID to
# /run/radvd/radvd.pid, matching the directory entrypoint.sh creates — a coupling neither file can state in code.
# `make gram.h` first works around a parallel-build race. radvdump ships as upstream's own RA decoder, which the README's HA and Healthcheck sections tell the operator to run.
RUN url="https://github.com/radvd-project/radvd/releases/download/${RADVD_VERSION}/radvd-${RADVD_VERSION#v}.tar.gz" \
    && tarball="${url##*/}" \
    && wget -q --timeout=30 "$url" \
    && echo "${RADVD_SHA256}  ${tarball}" | sha256sum -c - \
    && tar xzf "$tarball" --strip-components=1 --no-same-owner \
    && rm "$tarball" \
    && ./configure \
        --prefix=/usr \
        --with-pidfile=/run/radvd/radvd.pid \
    && make gram.h \
    && make -j"$(nproc)" \
    && strip radvd radvdump \
    && install -D -m 755 radvd /out/usr/sbin/radvd \
    && install -D -m 755 radvdump /out/usr/sbin/radvdump \
    && cat > /out/radvd.cdx.json <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "components": [
    {
      "bom-ref": "pkg:generic/radvd@${RADVD_VERSION#v}",
      "type": "application",
      "name": "radvd",
      "version": "${RADVD_VERSION#v}",
      "purl": "pkg:generic/radvd@${RADVD_VERSION#v}?download_url=${url}&checksum=sha256:${RADVD_SHA256}",
      "cpe": "cpe:2.3:a:radvd.litech:radvd:${RADVD_VERSION#v}:*:*:*:*:*:*:*"
    }
  ]
}
EOF

# radvd links against nothing beyond musl (already in the base), so no runtime lib packages are added.
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS base

# The `echo` is load-bearing: BuildKit keys a RUN on the build args it actually CONSUMES, not on a merely-declared ARG.
ARG PKG_REFRESH=static
RUN echo "OS package refresh: ${PKG_REFRESH}" && apk upgrade --no-cache
RUN addgroup -S radvd && adduser -S -D -H -G radvd radvd

COPY --from=builder /out/usr/sbin/ /usr/sbin/
# The release pipeline's Syft cataloger discovers the fragment by its .cdx.json suffix, not by this path; /usr/share/sbom is a fleet-wide convention, not a requirement.
COPY --from=builder /out/radvd.cdx.json /usr/share/sbom/radvd.cdx.json
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

FROM base AS test
ARG RADVD_VERSION
COPY tests/smoke.sh tests/radvd.conf tests/radvd.bad.conf /tmp/tests/
# The smoke test matches radvd's malformed-config rejection against the README's
# own alert-rule pattern, so that one fatal path keeps matching at least one
# alternative in the published rule; the rule's other alternatives are unpinned.
COPY README.md /tmp/README.md
COPY tests/shell /tmp/tests/shell
# lib.sh:29 puts REPO_ROOT at /tmp in the image, and startup_latch_test.sh:153
# reads $REPO_ROOT/CONTRIBUTING.md. Without this COPY the suite exits 1, no
# /tests-passed marker is written, and the COPY --from=test below fails the
# default-target build.
COPY CONTRIBUTING.md /tmp/CONTRIBUTING.md
# The suite's userland is the point: run.sh needs bash (installed here and
# discarded with this stage) while awk, sed, grep and tr are the image's
# BusyBox applets. The host CI run cannot see that axis — a ratified `sed`
# shape was green on GNU and 16 FAILs on BusyBox — and no container scenario
# reaches the block scanner at all, since no fixture carries AdvRASrcAddress.
# Two uid-gated cases skip under root here; the non-root CI run keeps them.
# ${RADVD_VERSION:?} fails the build if the ARG wiring breaks, so the in-image version assertion cannot be silently skipped.
# hadolint ignore=DL3018
RUN apk add --no-cache bash \
    && RADVD_EXPECTED_VERSION="${RADVD_VERSION:?}" sh /tmp/tests/smoke.sh \
    && ENTRYPOINT=/usr/local/bin/entrypoint.sh bash /tmp/tests/shell/run.sh \
    && touch /tests-passed

# `final` must remain last: the CI gate builds the default target. The marker COPY
# is what forces the test stage to build and pass first.
FROM base AS final
COPY --from=test /tests-passed /tests-passed

# Liveness only: it cannot see the HA-backup 'running but emitting no RAs' state — see the README 'Healthcheck' section.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD ["pidof", "radvd"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
