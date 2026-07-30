# OpenShift Deployment

This chart can deploy kagent on OpenShift using the same workload patterns as Kubernetes:

- `statefulset` for the standard persistent deployment
- `daemonset` for one kagent pod per node

Set `openshift.enabled=true` to enable OpenShift-specific rendering. By default, the chart uses an OpenShift restricted-v2 compatible security context by omitting fixed UID/GID fields and the default `NET_RAW` added capability. This lets OpenShift assign the runtime UID and SCC settings.

## Prerequisites

- OpenShift 4.x
- Helm 3.x
- A Kentik company ID
- A project/namespace where you can create the chart resources

## Standard Install

The recommended OpenShift install uses a StatefulSet, PVC storage, and Secret-backed keypair storage:

```bash
oc new-project kentik-kagent

helm install kagent oci://ghcr.io/kentik/kagent \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN \
  --set openshift.enabled=true
```

For a local checkout:

```bash
helm install kagent . \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set openshift.enabled=true
```

You can also start from [examples/openshift.yaml](../examples/openshift.yaml):

```bash
helm install kagent . -f examples/openshift.yaml
```

## Verify The Deployment

```bash
oc get pods -l app.kubernetes.io/name=kagent
oc logs -l app.kubernetes.io/name=kagent --tail=100
```

After the pod starts, authorize the pending agent in the Kentik Portal under Settings > Universal Agents.

## Security Contexts

OpenShift commonly runs pods under a namespace-assigned UID range. With `openshift.enabled=true`, the chart defaults to:

```yaml
openshift:
  enabled: true
  restrictedSecurityContext: true
```

This omits these chart defaults at render time:

- `podSecurityContext.runAsUser`
- `podSecurityContext.fsGroup`
- `securityContext.capabilities.add`

It also sets `podSecurityContext.seccompProfile.type=RuntimeDefault`.

Use this mode when deploying under OpenShift's default restricted SCCs.

## Machine ID / Host Identity

### Why kagent needs a machine ID

kagent uses a machine identifier to anchor its identity. On a normal Linux host this value
comes from `/etc/machine-id`, a 128-bit ID (32 lowercase hexadecimal characters) that is stable
for the life of the host. kagent expects this file to be present and stable so that a restarted
agent is recognized as the same agent rather than a brand-new one.

### The problem on OpenShift

Containers do not automatically inherit a usable `/etc/machine-id`, and on OpenShift the two
usual workarounds do not apply:

- **Mounting the host's `/etc/machine-id` is blocked.** `hostPath` volumes are not permitted by
  the default `restricted-v2` SCC, so the container cannot read the node's machine-id.
- **Sharing the node's machine-id would collide.** Even if it were mountable, every pod scheduled
  to the same node would present an identical machine-id, so multiple agents could not be told
  apart.

The result without this feature is either a missing/unstable machine-id or a value shared across
pods — both of which undermine per-agent identity.

### How the chart solves it

Set `kagent.machineId.enabled=true` to have the chart generate a stable, **identity-scoped**
`/etc/machine-id` for each pod:

```yaml
kagent:
  companyId: YOUR_COMPANY_ID
  machineId:
    enabled: true
```

The machine-id is derived from the pod's own keypair, which is the agent's identity on OpenShift
(see [Standard Install](#standard-install)). The resulting value:

- Uses the **standard Linux format**: 32 lowercase hexadecimal characters followed by a newline.
- Is **unique per agent identity**, so two pods on the same node never collide.
- Is **stable across restarts and rescheduling**, because it is derived from the pod's persistent,
  Secret-backed keypair rather than from anything on the node.
- Requires **no `hostPath` and no custom SCC** — it works under the default `restricted-v2` SCC.

### How it works internally

The feature is implemented entirely in the pod spec; nothing runs privileged and nothing touches
the node. When enabled:

1. The `setup-keypair` **init container** (which already stages the per-replica keypair) also
   writes the machine-id to a shared `emptyDir` volume at `/etc/kentik-machine-id/machine-id`:
   - **Normal case** — derived deterministically from the public key:
     `md5sum /opt/ua/keys/public_key.pem | cut -c1-32`. An MD5 digest is exactly 128 bits, so
     taking its 32 hex characters yields a value in the correct machine-id format that is a stable
     function of the identity.
   - **Pre-provisioning fallback** — if the keypair is not yet present, a 128-bit random value is
     written in the same format
     (`head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'`). Once the keypair exists on a later
     start, the deterministic value takes over.
2. The **main kagent container** mounts that file read-only at `/etc/machine-id` using a `subPath`,
   so the container sees a normal `/etc/machine-id` without any host access.

Volume flow:

```
init: setup-keypair ──writes──▶ emptyDir "machine-id"  (/etc/kentik-machine-id/machine-id)
                                        │
main: kagent  ──mounts read-only──▶ /etc/machine-id (subPath: machine-id)
```

### Requirements and scope

This feature only renders when **all** of the following hold, matching the recommended OpenShift
identity model:

- `deploymentType: statefulset`
- `persistence.keypair.enabled: true`
- `persistence.keypair.type: secret`

For any other configuration (for example DaemonSet, or a `hostPath`/`pvc` keypair) the
`kagent.machineId.enabled` flag is **ignored** and no `/etc/machine-id` is mounted. The setting is
opt-in and defaults to `false`, so it never changes existing deployments unless you enable it.
See [examples/openshift.yaml](../examples/openshift.yaml).

### Verifying

After the pod is running, confirm the file is present and correctly formatted:

```bash
oc exec -it <pod> -- cat /etc/machine-id
# e.g. 3f2a1c9b7d4e5f6081a2b3c4d5e6f708

# It should be 32 lowercase hex characters:
oc exec -it <pod> -- sh -c 'grep -Eq "^[0-9a-f]{32}$" /etc/machine-id && echo valid'
```

Because it is a `subPath` mount of a read-only file, the value stays constant for the life of the
pod. Two pods of the same StatefulSet return different values; the same pod returns the same value
across restarts.

> **Note:** This mounts a real `/etc/machine-id` file into the container. If a specific kagent
> capability instead reads the machine ID through the systemd `sd_id128_get_machine()` kernel API
> (rather than the file), a mounted file will not influence that path. If you are enabling this to
> solve a specific identity issue, confirm with the Kentik agent team that the component in
> question reads `/etc/machine-id` from disk.


## Capabilities And HostPath

Some kagent capabilities need Linux capabilities such as `NET_RAW`. DaemonSet deployments that use `hostPath` also need an SCC that allows host directory volumes. These permissions are not available under the default restricted SCC.

See the [Linux capabilities guide](capabilities.md) for the full per-capability reference of which UA capabilities require which Linux capabilities.

If your OpenShift administrator wants this chart to create and bind a custom SCC, enable it explicitly:

```yaml
openshift:
  enabled: true
  restrictedSecurityContext: false
  securityContextConstraints:
    create: true
    allowedCapabilities:
      - NET_RAW
```

Creating `SecurityContextConstraints` resources requires cluster-admin privileges. In many organizations, the preferred workflow is for a cluster administrator to create or approve the SCC separately, then bind it to the release service account.

For DaemonSet hostPath deployments, also allow host directory volumes:

```yaml
deploymentType: daemonset

openshift:
  enabled: true
  restrictedSecurityContext: false
  securityContextConstraints:
    create: true
    allowHostDirVolumePlugin: true
    allowedCapabilities:
      - NET_RAW

persistence:
  enabled: true
  type: hostPath
  keypair:
    enabled: true
    type: hostPath
```

## External Load Balancers And kproxy

For standard kagent deployments, pods generally only need outbound HTTPS access to Kentik. kproxy-style deployments also need inbound UDP telemetry from network devices, plus a TCP health check that the external load balancer can probe on each kagent endpoint.

OpenShift Routes are not a fit for UDP telemetry. Use a Service `type: LoadBalancer`, `NodePort`, or your platform's load balancer integration.

```yaml
deploymentType: daemonset

openshift:
  enabled: true

kagent:
  companyId: YOUR_COMPANY_ID
  healthCheck:
    enabled: true
    port: 8099

extraContainerPorts:
  - name: netflow
    containerPort: 9995
    protocol: UDP

service:
  enabled: true
  type: LoadBalancer
  externalTrafficPolicy: Local
  ports:
    - name: health
      port: 8099
      targetPort: health
      protocol: TCP
    - name: netflow
      port: 9995
      targetPort: netflow
      protocol: UDP
```

For DaemonSet intake, `externalTrafficPolicy: Local` is usually preferred because it keeps load-balanced traffic on nodes running a local kagent pod and can preserve source IP information when the platform supports it. Some load balancer implementations have limitations around mixed TCP and UDP listeners on the same Service; if that applies in your environment, create separate Services using the same selector, one for UDP intake and one for TCP health checks.

## Uninstall

```bash
helm uninstall kagent
```

StatefulSet PVCs are not deleted by Helm uninstall. Remove them only when you are sure the agent data and identity are no longer needed:

```bash
oc delete pvc -l app.kubernetes.io/name=kagent
```
