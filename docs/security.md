# Security

This page covers the privilege model, a read-only hardened profile, how to check the image signature and what the image contains. It is for operators who harden their deployment.

## Privilege model

radvd opens its raw ICMPv6 socket as root, then runs its worker as the unprivileged `radvd` user, leaving only a small root privilege-separation helper. The config mount is read-only. The container needs host networking and `NET_RAW`, both in [Configuration](configuration.md#capabilities).

## Hardened profile

Under `read_only: true`, `/run` must be a writable `tmpfs`, because radvd writes its PID file to the compiled-in `/run/radvd.pid`. Without a writable `/run`, radvd starts and then exits with `unable to open pid file, /run/radvd.pid: Read-only file system`, which the entrypoint passes on as `status="255"`. The `RadvdSupervisorFault` rule in [Monitoring](monitoring.md#alerting) reports it. Add this to the service in the README's quick start example:

```yaml
    read_only: true
    tmpfs:
      - /run:size=1m
    cap_drop:
      - ALL
    cap_add:
      - NET_RAW
      - SETUID
      - SETGID
      - KILL
    security_opt:
      - no-new-privileges:true
```

All four capabilities are already in Docker's default set, so this profile grants nothing the quick start example lacks. `cap_drop: ALL` is what makes listing them necessary. None of the four can be dropped further.

- `NET_RAW` opens the raw ICMPv6 socket radvd sends advertisements on. Without it radvd exits at startup with `open_icmpv6_socket: Operation not permitted`.
- `SETUID` and `SETGID` let radvd drop to the non-root `radvd` user. Without them radvd logs `unable to drop root privileges` and exits 1, which the quick start's `restart: unless-stopped` turns into a restart loop.
- `KILL` lets the root entrypoint signal its own non-root child. Without it both signal paths fail, and the entrypoint can only report the refusal. `docker stop` leaves radvd running while the entrypoint exits 0 and logs `a graceful stop cannot be confirmed`. The final zero-lifetime advertisement is never sent, so LAN hosts keep this node as their default router until the advertised lifetime expires. A `SIGHUP` logs `SIGHUP reload refused: TERM delivery to radvd could not be confirmed` and leaves radvd serving its last good config. The container stays up there on purpose, because a `docker kill` has already disarmed the restart policy, as [How it works](how-it-works.md#docker-kill-and-the-restart-policy) explains.

## Verifying the image

The image is published with [cosign](https://github.com/sigstore/cosign) signatures and SBOM attestations. Verify a pull:

```bash
cosign verify ghcr.io/cplieger/docker-radvd:latest \
    --certificate-identity-regexp '^https://github\.com/cplieger/ci/\.github/workflows/docker-release\.yaml@' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

CI lints the entrypoint with [shellcheck](https://www.shellcheck.net/) and the Dockerfile with [hadolint](https://github.com/hadolint/hadolint), scans for leaked secrets with [gitleaks](https://github.com/gitleaks/gitleaks), and scans the image with [trivy](https://trivy.dev/). Current scan results are in the repository's Security tab.

## What the image contains

| Component | Source |
| --- | --- |
| alpine | [Docker Hub](https://hub.docker.com/_/alpine) |
| radvd | [GitHub](https://github.com/radvd-project/radvd) (pinned source build) |

- radvd is compiled from the pinned upstream release tarball, the `RADVD_VERSION` build argument, and checked against a pinned SHA256 before extraction. The build applies no patches. The shipped daemon version is explicit and changes by pull request rather than floating with the Alpine package index.
- The Alpine base image is pinned by digest. The base userland around the radvd binary, musl and BusyBox among it, is upgraded at each image build, and scheduled rebuilds bound how stale a published image can get.
- `radvdump`, radvd's advertisement decoder, ships beside the daemon.
- radvd's own `COPYRIGHT` file is at `/usr/share/licenses/radvd/COPYRIGHT`. Alpine packages ship no license file, so their license texts are kept under `licenses/` in this repository and copied into `/usr/share/licenses/`.

[Renovate](https://github.com/renovatebot/renovate) updates the pinned radvd release and the Alpine base image. Before upgrading, read the [radvd changelog](https://github.com/radvd-project/radvd/blob/master/CHANGES) for `radvd.conf` syntax changes, because the mounted config is the only part that can break.
