# docker-radvd

Minimal Alpine-based container image for [radvd](https://radvd.litech.org/),
the Linux IPv6 Router Advertisement Daemon.

## Image

```
ghcr.io/cplieger/docker-radvd
```

Multi-arch (`linux/amd64`, `linux/arm64`), built, signed (cosign) and
SBOM-attested via the shared [`cplieger/ci`](https://github.com/cplieger/ci)
workflows.

## Usage

Provide a `radvd.conf` and run with host networking and the raw-socket /
admin capabilities radvd requires. See [`compose.yaml`](./compose.yaml).
