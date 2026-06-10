# check=error=true

FROM alpine:3.24.0@sha256:8ddefa941e689fc29abcdeb8dae3b3c6d139cc08ce9a52633931160701770685

# renovate: datasource=repology depName=alpine_3_23/radvd versioning=loose
ARG RADVD_VERSION=2.20-r0

RUN apk add --no-cache \
        radvd="${RADVD_VERSION}"

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof radvd >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
