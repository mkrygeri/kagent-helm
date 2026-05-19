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

## Capabilities And HostPath

Some kagent capabilities need Linux capabilities such as `NET_RAW`. DaemonSet deployments that use `hostPath` also need an SCC that allows host directory volumes. These permissions are not available under the default restricted SCC.

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

## Uninstall

```bash
helm uninstall kagent
```

StatefulSet PVCs are not deleted by Helm uninstall. Remove them only when you are sure the agent data and identity are no longer needed:

```bash
oc delete pvc -l app.kubernetes.io/name=kagent
```
