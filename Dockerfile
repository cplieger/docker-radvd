# check=error=true

FROM alpine:3.24.0@sha256:a2d49ea686c2adfe3c992e47dc3b5e7fa6e6b5055609400dc2acaeb241c829f4

# No apk version pin: the digest-pinned base above fixes the apk index, so the
# radvd version is already reproducible per base digest and floats forward on a
# base bump instead of stranding on an Alpine release change.
RUN apk add --no-cache \
        radvd
RUN grep -q '^radvd:' /etc/group || addgroup -S radvd; \
    grep -q '^radvd:' /etc/passwd || adduser -S -D -H -G radvd radvd

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof radvd >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
