# check=error=true

FROM alpine:3.23.4@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11

# renovate: datasource=repology depName=alpine_3_23/radvd versioning=loose
ARG RADVD_VERSION=2.20-r0

RUN apk add --no-cache \
        radvd="${RADVD_VERSION}"

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof radvd >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
