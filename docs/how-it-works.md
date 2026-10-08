# How docker-radvd works

This page explains what the image adds around radvd, how a reload works and why it is built this way. It is for operators who want to predict its behavior and for contributors.

## The design

- The image runs radvd and nothing else. It does no environment-to-config translation and bundles no prefixes, so you supply your own `radvd.conf`. The one variable, `RADVD_DEBUG_LEVEL`, only sets radvd's log verbosity.
- All configuration arrives through one read-only mount of `/etc/radvd`.
- radvd is compiled from the pinned upstream release tarball, not taken from the Alpine package index, so the shipped version changes only through a pull request.

## The entrypoint

A small POSIX shell entrypoint starts and supervises radvd.

- It checks the mounted `radvd.conf` path. It refuses a path that is not a regular file, at startup and on reload, and warns when its bounded read of the file fails. It leaves the config's settings to radvd. A config radvd rejects outright, such as one with no interface block, is left to radvd too. radvd logs its own error and exits, and the entrypoint reports that exit.
- It starts radvd with `--username=radvd`. radvd opens its raw socket as root, then runs its worker as the unprivileged `radvd` user. A small root privilege-separation helper stays beside it, so `ps` inside the container shows one radvd-owned process and one root-owned one.
- It turns `SIGHUP` into a config reload and forwards `SIGTERM`/`SIGINT` for a graceful shutdown. A stop that arrives before radvd has started wins at once and exits 0 without starting it. An unexpected radvd exit is passed on to Docker's restart policy.
- It logs structured `key=value` lines to standard error, which `docker logs` captures. radvd's own lines pass through unchanged.

## Reloading

On `SIGHUP`, the entrypoint restarts radvd so it reads the config again as root. radvd itself rereads its config as the unprivileged user on a reload. A config file only root can read would then make radvd's own reload fail and exit. Supervising and restarting the daemon, rather than replacing the entrypoint with radvd, makes the reload work whatever the file's ownership.

Most bad edits are refused before anything stops, so the running radvd keeps serving its last good config. Five cases are refused, each logging `SIGHUP reload refused`:

- the file is malformed, and radvd's own text follows
- the file is absent or not a regular file
- the check takes longer than 5 seconds
- radvd calls the file's permissions insecure, and radvd's own text follows
- the entrypoint could not confirm that its TERM reached radvd

After an accepted check stops radvd, the entrypoint checks the path again before starting the replacement. It exits when the path is no longer a regular file, and warns without stopping when the file cannot be read.

The check is `radvd --configtest` under the daemon's own `--username=radvd`, which runs radvd's config parser and nothing after it. So anything radvd checks later passes it. That covers the interface's presence, every bound radvd checks after parsing, such as `MinRtrAdvInterval` against 3/4 of `MaxRtrAdvInterval`, `AdvDefaultLifetime` and MTU, and a config replaced between the check and the daemon's own read. File permissions are the exception, because the check runs as the daemon's user and prints the verdict.

What happens after a bad edit passes the check depends on `IgnoreIfMissing`. With `off`, radvd exits and the container with it. With `on`, radvd's default, radvd keeps running and healthy while that interface sends nothing at all. Either way the evidence is radvd's own error line, such as `MinRtrAdvInterval for eth0 (200.00) must be at least 3.00 but no more than 3/4 of MaxRtrAdvInterval (180.00)`. Check with `rdisc6` after any config change. The `RadvdConfigError` rule in [Monitoring](monitoring.md#alerting) matches these lines.

`docker restart` takes none of this check. It starts from the beginning, so a bad edit exits radvd and the container restarts in a loop until the config is fixed.

### What every reload does on the wire

Because a reload restarts the daemon, the outgoing radvd sends a final advertisement with Router Lifetime 0 on its way out, and logs `sending stop adverts`. That is radvd's default `RemoveAdvOnExit` setting, and radvd's own in-process reload does not do it. So every accepted reload, and every `docker restart`, briefly withdraws this node as an IPv6 default router until the replacement's first advertisement. Where another device is the gateway and `AdvDefaultLifetime 0` is set, that changes nothing. Where this radvd is the default router, every reload drops the default route on SLAAC hosts for that interval.

A successful reload also logs two radvd lines at ERROR level as the old daemon exits, `Exiting, privsep_read_loop had readn return 0 bytes` and `Exiting, privsep_read_loop is complete.`. They come from radvd's privilege-separation helper noticing its worker is gone. They appear on every reload and every graceful stop, and they are normal.

### docker kill and the restart policy

`docker kill` cancels the container's restart policy for the rest of the run. It does so for any signal when the container sets no `stop_signal`, and neither this image nor the shipped `compose.yaml` sets one. With a `stop_signal` set, it does so for `SIGKILL` or the configured stop signal. Crash recovery then stays off until the next `docker start` or `docker restart`. An operator who sets `stop_signal` keeps `always` and `on-failure` armed for other signals, while `unless-stopped` is disarmed by the kill regardless.

This image's crash recovery is that restart policy, so the README leads with `docker restart`. `docker exec radvd kill -HUP 1` sends the same reload signal from inside the container. It keeps the restart policy armed, because the Docker API kill call, not the signal, is what disarms it.

## Healthcheck and exit

The healthcheck runs `pidof radvd` every 30 seconds, with a 5 second timeout, 3 retries and a 15 second start period. It is a liveness probe only, and it is not what reacts to a crash. When radvd dies, the entrypoint passes the exit on and the container stops within a second, so your `restart` policy handles a crash rather than the container ageing into `unhealthy`. The `docker kill` caveat above applies.

Neither the probe nor that exit sees a radvd that runs but sends nothing. On an HA BACKUP node that is intended. With IPv6 forwarding off on the host, radvd also runs and reports healthy, and an advertisement with a non-zero `AdvDefaultLifetime` still names this node as a default router while the kernel forwards nothing. `rdisc6` shows the advertisement, but only the host's sysctl shows whether the advertised route works.
