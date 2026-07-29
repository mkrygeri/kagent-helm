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

helm install kagent oci://ghcr.io/kentik/kagent-helm \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
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

kagent uses a machine identifier to anchor its identity. On a normal host this comes from `/etc/machine-id`, but on OpenShift that path cannot be mounted from the host (hostPath is blocked by the restricted SCC), and on a shared node it would be identical for every pod on that node.

Enable `kagent.machineId.enabled=true` to have the chart provide a stable, per-identity `/etc/machine-id` instead:

```yaml
kagent:
  companyId: YOUR_COMPANY_ID
  machineId:
    enabled: true
```

When enabled, the `setup-keypair` init container derives the machine-id from the pod's own public key and mounts it at `/etc/machine-id`. The result:

- Uses the standard Linux format: 32 lowercase hexadecimal characters.
- Is **unique per agent identity**, so two pods on the same node do not collide.
- Is **stable across restarts**, because it is derived from the pod's persistent keypair.
- Requires **no hostPath and no custom SCC** — it works under the default `restricted-v2` SCC.

This feature requires `deploymentType=statefulset` with `persistence.keypair.type=secret` (the recommended OpenShift identity model) and is ignored for other configurations. See [examples/openshift.yaml](../examples/openshift.yaml).

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
