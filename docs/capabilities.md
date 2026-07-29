# Linux Capabilities And kagent

kagent (the Kentik Universal Agent) itself needs **no special Linux capabilities**. It runs
non-root (uid 500), only writes to `/opt/kentik`, and works under a restricted / strict
Pod Security namespace with `capabilities.drop: ALL`.

Individual Universal Agent (UA) **capabilities** — the collection features you enable in the
Kentik portal, such as flow collection, SNMP polling, or synthetics — may each require one or
more Linux kernel capabilities to be added back. Add only the ones needed by the UA
capabilities you actually run, following the principle of least privilege.

Set the required Linux capabilities under `securityContext.capabilities.add` in your values:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
    add:
      - NET_RAW
```

The chart default is `drop: ALL` with `add: [NET_RAW]`, which covers the default NMS use case.

## Per-Capability Requirements

| UA capability | Component | Linux capabilities to add | Notes |
|---------------|-----------|---------------------------|-------|
| Flow Proxy | kproxy | *(none)* | Listens on 9995 (non-privileged). Needs `NET_BIND_SERVICE` only if rebound to a port below 1024. |
| Flow Proxy (new) | ktraffic | `NET_RAW` | |
| BGP Proxy | kbgp | *(none)* | Needs `NET_BIND_SERVICE` only if bound to a privileged port. |
| DNS OTT Tap | kdns | `NET_RAW` | |
| NMS / ranger (SNMP) | ranger | `NET_RAW` | Packet capture. |
| Synthetics | ksynth | `NET_RAW` | |
| Connectivity Test | livesynth | `NET_RAW`, `SYS_CHROOT`, `SETUID`, `SETGID` | ping / traceroute. |
| Syslog Server | ksyslog | `NET_BIND_SERVICE` | Default port 514 is privileged. |
| SNMP Trap Receiver | ksnmptrap | `NET_BIND_SERVICE` | Default port 162 is privileged. |
| Reverse DNS | kptr | *(none)* | |
| Config Scraper | ksqueegee | *(none)* | |

## When Zero Linux Capabilities Are Needed

You can run kagent with an **empty** `add` list (`add: []`, keeping `drop: ALL`) when you only
enable UA capabilities that require none:

- kptr (Reverse DNS)
- ksqueegee (Config Scraper)
- kproxy (Flow Proxy) on its default port 9995
- kbgp (BGP Proxy) on its default (non-privileged) port

This is the minimal-privilege configuration and is fully compatible with a restricted Pod
Security namespace.

## OpenShift

Under OpenShift, added capabilities are governed by the assigned SecurityContextConstraints
(SCC). The default `restricted-v2` SCC does not allow adding capabilities such as `NET_RAW`.
See the [OpenShift deployment guide](openshift.md) for how to enable a custom SCC that grants
the specific capabilities your enabled UA capabilities need.
