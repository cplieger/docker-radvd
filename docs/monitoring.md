# Monitoring and alerts

This page covers what radvd and the entrypoint log, how to check what reaches the LAN, and the alert rules. It is for operators who watch the container from Loki and Alertmanager.

## What it logs

radvd has no metrics endpoint, and its state is in its logs. The entrypoint writes structured `level=... msg="..."` lines to standard error, and radvd writes its own lines there unchanged. `docker logs radvd` shows both.

At the default `RADVD_DEBUG_LEVEL=0`, radvd logs `<iface> received RS or RA on <iface> but <iface> is not ready and setup_iface failed` whenever a solicitation or advertisement arrives on an interface it never finished bringing up. That is the expected steady state on an HA BACKUP node, where the MASTER's own advertisements trigger it. On a single node it means radvd is not advertising. There, router solicitations from LAN hosts raise the line, but only when this node advertises a default route and the host forwards IPv6. Nothing in the line tells those cases apart, which is why no rule below matches it. Set `RADVD_DEBUG_LEVEL=5` for the cause, `no configured AdvRASrcAddress present, skipping send`.

When radvd sets an interface up with `IgnoreIfMissing on` and the interface is missing, it logs `ignoring the interface (setup_iface=...)`. That is a normal HA BACKUP state, not an alert, and radvd logs it at debug level 4, so at level 0 it does not appear at all. It carries no `not found:` line either, because radvd prints that only when the device is absent.

## Checking what reaches the LAN

The image ships radvd's own advertisement decoder. `docker exec radvd radvdump` reads the advertisements that other routers put on the segment, so run it on the peer node to confirm the BACKUP stays silent. It does not show this container's own advertisements. radvd turns off IPv6 multicast loopback on the socket it sends from, so the kernel never hands them back to a local listener. On a single node `radvdump` therefore stays empty however well radvd works.

For this node's own output, run a probe that listens on the LAN segment from another host:

```bash
# On any IPv6 host on the LAN:
sudo rdisc6 eth0
```

An advertisement from your radvd source address within a few seconds means it works.

## Alerting

Ship the container's logs to Loki and load the rules in [`alerts/logql.yaml`](../alerts/logql.yaml) into [Loki's ruler](https://grafana.com/docs/loki/latest/alert/). Grafana Alloy's Docker log discovery ships them with no extra configuration. Firing alerts go through your Alertmanager like any Prometheus alert. They cover:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `RadvdConfigError` | radvd or the entrypoint rejects the config or a reload, or a peer advertises from a non-link-local address | warning |
| `RadvdAdvertisementsUnverified` | the entrypoint cannot read the mounted `radvd.conf`, so nothing confirms advertisements are sent | warning |
| `RadvdForwardingDisabled` | radvd advertises a default route while IPv6 forwarding is off on the host | warning |
| `RadvdSupervisorFault` | the entrypoint cannot stop radvd, or radvd exits unexpectedly | warning |

radvd's lines arrive only on a config error or an event, with no periodic heartbeat, so the rules are fault rules only. The healthcheck covers a dead process.

Every pattern is a string radvd or the entrypoint emits, checked against radvd's source at the pinned version. `properly \(setup_iface=` is anchored on the opening parenthesis so it matches only the fatal form, not the normal `ignoring the interface (setup_iface=` form above. The parameter-bound fragments are radvd's wording at the pinned version, so a reword in a later release narrows a rule silently. That costs a missed alert, never a false one.

Thresholds and the `severity` label are starting points. The `container` selector and the `hostname` grouping label depend on your log collector. Alloy's Docker discovery provides `container`, while `hostname` comes from your own labeling, so adjust or drop `sum by (hostname)` to match. Route by whatever labels your Alertmanager uses.
