# check=error=true

# renovate: datasource=github-tags depName=radvd-project/radvd
ARG RADVD_VERSION=v2.21
# github-tags exposes the git sha, not the tarball hash, hence the repin marker.
# repin: dep=radvd-project/radvd url=https://github.com/radvd-project/radvd/releases/download/{version}/radvd-{version_nov}.tar.gz
ARG RADVD_SHA256=09e5cf7712397463fd35ebca71f3c05f7d31cff9246513f12d03a359c40b089c

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache bison build-base flex linux-headers pkgconf

ARG RADVD_VERSION
ARG RADVD_SHA256
WORKDIR /build/radvd
# Fetch the release ASSET, not the auto-generated tag archive: only the asset's bytes are stable enough to SHA-pin.
# The CycloneDX fragment is emitted from this same RUN so the URL is spelled once — the bytes fetched, the digest
# verified and the published download_url cannot drift apart. CPE: the NVD dictionary carries exactly one
# vendor:product for radvd, radvd.litech:radvd; the sometimes-guessed litech:router_advertisement_daemon has no entry.
# --with-pidfile keeps radvd writing its PID to /run/radvd/radvd.pid, matching the directory entrypoint.sh creates —
# a coupling neither file can state in code. `make gram.h` first works around a parallel-build race.
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
    && install -D -m 644 defaults.h /out/radvd-src/defaults.h \
    # Syft inventories the final image from Alpine's APK database only, so this
    # source-built payload is invisible to the signed release SBOM without it.
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

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS base

ARG PKG_REFRESH=static
# The `echo` is load-bearing: BuildKit keys a RUN on the args it CONSUMES, so dropping it
# leaves the upgrade on a cached layer and the image ships stale packages, silently.
RUN echo "OS package refresh: ${PKG_REFRESH}" \
    && apk upgrade --no-cache \
    && addgroup -S radvd \
    && adduser -S -D -H -G radvd radvd

COPY --from=builder /out/usr/sbin/ /usr/sbin/
COPY --from=builder /out/radvd.cdx.json /usr/share/sbom/radvd.cdx.json
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

FROM base AS test
ARG RADVD_VERSION
COPY tests/smoke.sh tests/radvd.conf tests/radvd.bad.conf /tmp/tests/
# tests/smoke.sh matches radvd's malformed-config rejection against the README's
# own alert-rule pattern, so that fatal path keeps matching the published rule.
COPY README.md /tmp/README.md
COPY tests/shell /tmp/tests/shell
# lib.sh puts REPO_ROOT at /tmp in the image and startup_latch_test.sh reads
# $REPO_ROOT/CONTRIBUTING.md; without this COPY the suite exits 1 and no marker
# is written.
COPY CONTRIBUTING.md /tmp/CONTRIBUTING.md
# The AdvSendAdvert check is only correct while upstream defaults the directive to
# off, so the build reads that default out of the header it compiled against.
COPY --from=builder /out/radvd-src/defaults.h /tmp/radvd-defaults.h
# The suite's userland is the point: run.sh needs bash (installed here and discarded
# with this stage) while awk, sed, grep and tr are the image's BusyBox applets — a
# host-only run can be green while BusyBox fails.
# ${RADVD_VERSION:?} fails the build if the ARG wiring breaks, so the in-image version assertion cannot be silently skipped.
RUN apk add --no-cache bash \
    && RADVD_EXPECTED_VERSION="${RADVD_VERSION:?}" sh /tmp/tests/smoke.sh \
    && ENTRYPOINT=/usr/local/bin/entrypoint.sh bash /tmp/tests/shell/run.sh \
    && touch /tests-passed

# `final` must remain last: the CI gate builds the default target, and the marker
# COPY is what forces the test stage to build and pass first.
FROM base AS final
COPY --from=test /tests-passed /tests-passed

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD ["pidof", "radvd"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
