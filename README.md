# Kagent Helm Chart

A Helm chart for deploying Kentik Universal Agent (kagent) with support for multiple deployment patterns: StatefulSet and DaemonSet. OpenShift-specific deployment support is available with `openshift.enabled=true`.

## Prerequisites

- Kubernetes 1.20+
- Helm 3.x
- Kentik account with API access
- A provisioning token (if you cloned this repo, see `./generate-provisioning-token.sh --help`)

## Quick Start

### 1. Install the Chart

```bash
# Clone the repository
git clone https://github.com/kentik/kagent-helm.git
cd kagent-helm

# Install with StatefulSet pattern (persistent storage)
helm install kagent . \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN
```

Alternatively, install directly from the published OCI chart without cloning:

```bash
# Install the latest published chart from the GitHub Container Registry
helm install kagent oci://ghcr.io/kentik/kagent \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN

# Or pin a specific chart version
helm install kagent oci://ghcr.io/kentik/kagent \
  --version 1.1.0 \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN
```

> The chart is packaged and published to `oci://ghcr.io/<owner>/kagent` by the
> [Release workflow](.github/workflows/release.yaml) whenever a `v*.*.*` tag is pushed.
> Forks publish under their own owner (for example `oci://ghcr.io/mkrygeri/kagent`).


### 2. Verify Installation

```bash
# Check deployment status
kubectl get pods -l app.kubernetes.io/name=kagent

# View logs
kubectl logs -l app.kubernetes.io/name=kagent --tail=100
```

### 3. Authorize agent via UI
- Go to Kentik Portal → Settings → Universal Agents
- Find your new agent in the "Pending Authorization" section
- Click "Authorize" to approve the agent

## Deployment Patterns


### StatefulSet (Persistent Storage)

**Use Case**: Standard deployments requiring persistent storage for flow data buffers or agent state.

**Characteristics**:
- Ordered pod naming (kagent-0, kagent-1, ...)
- Persistent volumes for data and keypair
- Stable identity across pod restarts
- Ordered rolling updates

**Important**: The agent's ed25519 keypair is stored in `/opt/ua/keys/` and **MUST** persist across pod restarts as it's the agent's unique identity.

**Data Persistence**:
The StatefulSet creates two persistent volumes per pod:
- `/data` (10Gi default): Application data, buffers, logs, temp files
- `/opt/ua/keys` (100Mi): ed25519 keypair (agent identity)

**Scaling**:

Before scaling, you need to ensure that the secret with agent's identity includes keypairs for each additional agent (if scaling up). Then you can run a regular scale command:

```bash
# Scale StatefulSet
kubectl scale statefulset kagent --replicas=3
```

**Cleanup**: PVCs are NOT deleted automatically on uninstall:
```bash
# Delete the release
helm uninstall kagent

# Manually clean up PVCs
kubectl delete pvc -l app.kubernetes.io/name=kagent
```

### DaemonSet (Node-Level)

**Use Case**: Node-level network monitoring, SNMP polling of node interfaces, or collecting node-specific metrics.

**Characteristics**:
- Exactly one pod per Kubernetes node
- Automatic pod scheduling on node add/remove
- Tolerations for control-plane nodes included
- Lower resource requests per pod

**Storage**:
DaemonSet deployments only support `hostPath` for persistent storage (not PVC). Set `persistence.type: hostPath` when using DaemonSet.

Check [examples/daemon-set.yaml](examples/daemon-set.yaml) to get started.

**hostPath Permissions**:
The hostPath directories on each node must be readable and writable by user ID 500 (the default `runAsUser`). Create and set permissions before deploying:

```bash
# On each node, create directories with correct ownership
sudo mkdir -p /var/lib/kagent/data /var/lib/kagent/keys
sudo chown -R 500:500 /var/lib/kagent
```

**Node Coverage**:
```bash
# Verify one pod per node
kubectl get nodes --no-headers | wc -l
kubectl get pods -l app.kubernetes.io/name=kagent --no-headers | wc -l
# These numbers should match

# View pods with node assignment
kubectl get pods -l app.kubernetes.io/name=kagent -o wide
```

### OpenShift

OpenShift deployments use the existing StatefulSet or DaemonSet patterns with OpenShift-specific security-context rendering enabled:

```bash
helm install kagent . \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set openshift.enabled=true
```

See the dedicated [OpenShift deployment guide](docs/openshift.md) for restricted SCC deployments, optional custom SCC creation, and DaemonSet hostPath guidance.

## External Load Balancers And kproxy

Most kagent deployments only initiate outbound HTTPS connections to Kentik and do not need an inbound Service. kproxy-style deployments are different: kagent receives UDP telemetry such as NetFlow/IPFIX/sFlow from network devices, then forwards the processed data to Kentik over HTTPS.

For kproxy UDP intake, enable a Kubernetes `Service` of type `LoadBalancer` or `NodePort` and expose both:

- One or more UDP intake ports for telemetry from network devices
- A TCP health check port so the external load balancer can determine which kagent endpoints are healthy

The health check server is controlled by `kagent.healthCheck` and maps to `K_HC_SERVER_*` environment variables:

```yaml
kagent:
  healthCheck:
    enabled: true
    port: 8099
```

The chart automatically exposes the health check as a named container port when `kagent.healthCheck.enabled=true`, probes are enabled, or `service.enabled=true`. Add UDP intake ports through `extraContainerPorts`, then publish them with `service.ports`:

```yaml
deploymentType: daemonset

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

See [docs/kproxy-loadbalancer-values.yaml](docs/kproxy-loadbalancer-values.yaml) for a complete starting point.

### Choosing A Load Balancer Pattern

**StatefulSet** is best when kagent primarily needs durable identity and storage. A single LoadBalancer Service can distribute UDP across replicas, but the external load balancer sees the Kubernetes Service as one backend set. Use this when per-node intake is not required.

**DaemonSet** is usually the better kproxy intake pattern. It runs one kagent per node and pairs well with `externalTrafficPolicy: Local`, which keeps load-balanced traffic on nodes that have a local kagent endpoint and preserves the original source IP when the platform supports it.

**OpenShift** uses the same Service model. For OpenShift Route, remember that Routes are HTTP/TLS focused and are not suitable for UDP telemetry. Use a Service `type: LoadBalancer`, `NodePort`, or platform-specific load balancer integration for UDP intake.

## Configuration

### Kagent Settings

| Parameter | Description | Default |
|-----------|-------------|---------|
| `kagent.companyId` | Company ID for agent registration (REQUIRED) | `""` |
| `kagent.provisioningToken` | Provisioning token for agent registration (REQUIRED; stored in a Kubernetes Secret and injected via `secretKeyRef`) | `""` |
| `kagent.agentId` | Agent ID for Terraform tracking | `""` |
| `kagent.releaseChannel` | Release channel (stable, beta, dev) | `stable` |
| `kagent.diskReservation.enabled` | Enable disk space reservation | `true` |
| `kagent.diskReservation.initialSize` | Initial reserved disk space | `200MB` |
| `kagent.logDest` | Log destination (stdout, stderr, discard, filename) | `stdout` |
| `kagent.logLevel` | Log level (debug, info, warn, error) | `info` |
| `kagent.apiEndpoint` | Kentik API endpoint | `grpc.api.kentik.com:443` |
| `kagent.machineId.enabled` | Provide a stable, identity-scoped `/etc/machine-id` (32 lowercase hex chars) derived from the pod keypair instead of the host machine-id. Requires `deploymentType=statefulset` with `persistence.keypair.type=secret`. Recommended for OpenShift. | `false` |

### Deployment Configuration

| Parameter | Description | Default         |
|-----------|-------------|-----------------|
| `deploymentType` | Pattern: statefulset, daemonset | `statefulset`   |
| `replicaCount` | Number of replicas (StatefulSet only) | `1`             |
| `image.repository` | Kagent container image | `kentik/kagent` |
| `image.tag` | Image tag | `v5.0.1`        |
| `image.pullPolicy` | Image pull policy | `IfNotPresent`  |

### Persistence

| Parameter | Description | Default |
|-----------|-------------|---------|
| `persistence.enabled` | Enable persistent storage | `true` |
| `persistence.type` | Volume type: `pvc`, `hostPath`, `emptyDir` | `pvc` |
| `persistence.pvc.storageClass` | Storage class (empty = cluster default) | `""` |
| `persistence.pvc.size` | Data volume size | `10Gi` |
| `persistence.pvc.accessModes` | PVC access modes | `[ReadWriteOnce]` |
| `persistence.hostPath.path` | Host path for data (DaemonSet) | `/var/lib/kagent/data` |
| `persistence.hostPath.type` | HostPath volume type | `DirectoryOrCreate` |
| `persistence.keypair.enabled` | Separate volume for keypair | `true` |
| `persistence.keypair.type` | Keypair storage: `secret`, `pvc`, `hostPath`, `emptyDir` | `secret` |
| `persistence.keypair.pvc.storageClass` | Storage class for keypair PVC | `""` |
| `persistence.keypair.pvc.size` | Keypair volume size (when using PVC) | `100Mi` |
| `persistence.keypair.pvc.accessModes` | Keypair PVC access modes | `[ReadWriteOnce]` |
| `persistence.keypair.hostPath.path` | Host path for keypair (DaemonSet) | `/var/lib/kagent/keys` |
| `persistence.keypair.hostPath.type` | Keypair hostPath volume type | `DirectoryOrCreate` |
| `persistence.keypair.secret.name` | Secret name pattern (empty = auto-generated) | `""` |

### Resources

| Parameter | Description | Default |
|-----------|-------------|---------|
| `resources.requests.cpu` | CPU request | `100m` (50m for DaemonSet) |
| `resources.requests.memory` | Memory request | `128Mi` (64Mi for DaemonSet) |
| `resources.limits.cpu` | CPU limit | `500m` (200m for DaemonSet) |
| `resources.limits.memory` | Memory limit | `512Mi` (256Mi for DaemonSet) |

### Security

| Parameter | Description | Default |
|-----------|-------------|---------|
| `podSecurityContext.runAsNonRoot` | Run as non-root user | `true` |
| `podSecurityContext.runAsUser` | User ID | `500` |
| `podSecurityContext.fsGroup` | File system group | `500` |
| `serviceAccount.create` | Create service account | `true` |
| `rbac.create` | Create RBAC resources | `false` |
| `networkPolicy.enabled` | Enable network policy | `false` |

kagent itself needs no special Linux capabilities. Individual Universal Agent capabilities
(flow, SNMP, synthetics, syslog, etc.) may each require specific capabilities under
`securityContext.capabilities.add`. See the [Linux capabilities guide](docs/capabilities.md)
for the full per-capability reference.


### Health Checks And Services

| Parameter | Description | Default |
|-----------|-------------|---------|
| `kagent.healthCheck.enabled` | Enable the kagent health check server | `false` |
| `kagent.healthCheck.network` | Health check listener network (`tcp`, `tcp4`, `tcp6`) | `tcp4` |
| `kagent.healthCheck.port` | Health check listener port | `8099` |
| `kagent.healthCheck.address` | Health check listen address (empty = `:<port>`) | `""` |
| `extraContainerPorts` | Additional container ports, such as UDP kproxy intake ports | `[]` |
| `service.enabled` | Create a Service for inbound traffic | `false` |
| `service.type` | Service type: `ClusterIP`, `NodePort`, `LoadBalancer` | `ClusterIP` |
| `service.annotations` | Service annotations for cloud/provider load balancers | `{}` |
| `service.externalTrafficPolicy` | External traffic policy for `NodePort`/`LoadBalancer` | `""` |
| `service.loadBalancerIP` | Static load balancer IP, when supported | `""` |
| `service.loadBalancerSourceRanges` | Allowed source CIDRs for the load balancer | `[]` |
| `service.ports` | Service ports for TCP health checks and UDP intake | health TCP 8099 |

### OpenShift

| Parameter | Description | Default |
|-----------|-------------|---------|
| `openshift.enabled` | Enable OpenShift-specific rendering behavior | `false` |
| `openshift.restrictedSecurityContext` | Omit fixed UID/GID fields and added capabilities for restricted-v2 SCC compatibility | `true` |
| `openshift.securityContextConstraints.create` | Create a custom OpenShift SecurityContextConstraints resource | `false` |
| `openshift.securityContextConstraints.name` | Custom SCC name (empty = generated) | `""` |
| `openshift.securityContextConstraints.allowHostDirVolumePlugin` | Allow hostPath volumes in the custom SCC | `false` |
| `openshift.securityContextConstraints.allowHostNetwork` | Allow host networking in the custom SCC | `false` |
| `openshift.securityContextConstraints.allowPrivilegedContainer` | Allow privileged containers in the custom SCC | `false` |
| `openshift.securityContextConstraints.allowedCapabilities` | Linux capabilities allowed by the custom SCC | `[NET_RAW]` |

## Cloud-Specific Examples

### AWS (EKS)

```yaml
# statefulset-aws-gp3.yaml
deploymentType: statefulset
persistence:
  pvc:
    storageClass: "gp3"
  keypair:
    pvc:
      storageClass: "gp3"
```

### Azure (AKS)

```yaml
# statefulset-azure-premium.yaml
deploymentType: statefulset
persistence:
  pvc:
    storageClass: "managed-premium"
  keypair:
    pvc:
      storageClass: "managed-premium"
```

### Google Cloud (GKE)

```yaml
# statefulset-gcp-standard.yaml
deploymentType: statefulset
persistence:
  pvc:
    storageClass: "standard-rwo"
  keypair:
    pvc:
      storageClass: "standard-rwo"
```

## Migration Between Patterns

**IMPORTANT**: Switching between deployment patterns (e.g., DaemonSet → StatefulSet) requires a **clean uninstall and fresh install**. In-place upgrades between patterns are NOT supported due to Kubernetes resource type immutability.

```bash
# Uninstall existing release
helm uninstall kagent

# Clean up PVCs if switching from StatefulSet
kubectl delete pvc -l app.kubernetes.io/name=kagent

# Install with new pattern
helm install kagent . --set deploymentType=statefulset
```

## Troubleshooting

### Agent Not Connecting

1. **Check provisioning token**:
```bash
kubectl get secret kagent-secret -o jsonpath='{.data.K_REGISTER_PROVISIONING_TOKEN}' | base64 -d
```

2. **View agent logs**:
```bash
kubectl logs -l app.kubernetes.io/name=kagent --tail=100
```

3. **Verify network connectivity**:
```bash
kubectl exec -it <pod-name> -- ping grpc.api.kentik.com
```

### StatefulSet PVC Issues

1. **Check PVC status**:
```bash
kubectl get pvc -l app.kubernetes.io/name=kagent
```

2. **Verify storage class exists**:
```bash
kubectl get storageclass
```

3. **Check pod volume mounts**:
```bash
kubectl exec -it kagent-0 -- ls -la /data
kubectl exec -it kagent-0 -- ls -la /opt/ua/keys
```

### Keypair Persistence Issues

**Problem**: Agent creates new identity after pod restart, or pod fails to start with keypair errors.

#### Using Secret-Based Storage

1. **Verify secrets exist and have correct names**:
```bash
# List all kagent secrets
kubectl get secrets | grep kagent

# Should show: kagent-0-secret, kagent-1-secret, etc.
# Verify secret content
kubectl get secret kagent-0-secret -o yaml

# Check that it has the required keys
kubectl get secret kagent-0-secret -o jsonpath='{.data}' | jq 'keys'
# Should output: ["private_key.pem", "public_key.pem"]
```

2. **Verify secret content is valid**:
```bash
# Decode and check private key format
kubectl get secret kagent-0-secret -o jsonpath='{.data.private_key\.pem}' | base64 -d
# Should start with: -----BEGIN PRIVATE KEY-----

# Decode and check public key format
kubectl get secret kagent-0-secret -o jsonpath='{.data.public_key\.pem}' | base64 -d
# Should start with: -----BEGIN PUBLIC KEY-----
```

3. **Check pod init container logs** (when using secret type):
```bash
# View init container logs
kubectl logs kagent-0 -c setup-keypair

# Should show: "Keypair for pod-0 copied successfully"
# If you see "Warning: No keypair found", the secret name is incorrect
```

4. **Verify keypair was mounted correctly**:
```bash
# Check if keys exist in the container
kubectl exec -it kagent-0 -- ls -la /opt/ua/keys/
# Should show: private_key.pem, public_key.pem

# Verify permissions
kubectl exec -it kagent-0 -- stat /opt/ua/keys/private_key.pem
# Should show mode: 0400 (read-only)
```

#### Using PVC-Based Storage

1. **Check PVC status**:
```bash
# List keypair PVCs
kubectl get pvc | grep keys

# Verify PVC is bound
kubectl get pvc keys-kagent-0
# Status should be "Bound"
```

2. **Verify mount inside pod**:
```bash
kubectl exec -it kagent-0 -- ls -la /opt/ua/keys/
# Should show: agent.key (private key), agent.pub (public key)
```

3. **Check if keys persist across restarts**:
```bash
# Note the key fingerprint
kubectl exec -it kagent-0 -- cat /opt/ua/keys/agent.pub

# Delete the pod (StatefulSet will recreate it)
kubectl delete pod kagent-0

# Wait for pod to restart
kubectl wait --for=condition=Ready pod/kagent-0 --timeout=60s

# Verify the same key exists
kubectl exec -it kagent-0 -- cat /opt/ua/keys/agent.pub
# Should match the previous fingerprint
```

#### Common Issues

**Issue**: `Error: secret "kagent-0-secret" not found`
- **Cause**: Secrets not created before helm install
- **Solution**: Create secrets first (see [Generating Keypairs](#option-1-generating-keypairs-with-helper-script))

**Issue**: `Warning: No keypair found for pod-X`
- **Cause**: Secret name doesn't match expected pattern
- **Solution**: Ensure secret name is `{{ .Release.Name }}-{{ replica-index }}-secret`

**Issue**: Pod stuck in `Init:Error` state
- **Cause**: Invalid secret content or missing keys
- **Solution**: Verify secret has both `private_key.pem` and `public_key.pem` keys with valid PEM content

**Issue**: Agent shows "Keypair validation failed"
- **Cause**: Corrupted or invalid keypair format
- **Solution**: Regenerate keypair using `generate-secrets.sh` or verify external secret manager integration

### DaemonSet Not on All Nodes

1. **Check node taints**:
```bash
kubectl get nodes -o json | jq '.items[].spec.taints'
```

2. **Verify tolerations are applied**:
```bash
kubectl get daemonset kagent -o yaml | grep -A 10 tolerations
```

3. **Check node selectors**:
```bash
# If you have node selectors, ensure nodes have matching labels
kubectl get nodes --show-labels
```

## Advanced Configuration

### Keypair Management

The agent's ed25519 keypair serves as its unique identity in the Kentik platform. **This keypair MUST persist across pod restarts** to maintain the agent's identity and prevent orphaned agents.

#### Storage Options

The chart supports four keypair storage types via `persistence.keypair.type`:

1. **`secret`** (Default, Recommended): Kubernetes Secrets - best for production, GitOps, and external secret managers
2. **`pvc`**: PersistentVolumeClaim - traditional persistent storage approach
3. **`hostPath`**: Node-local storage - useful for DaemonSet deployments
4. **`emptyDir`**: Temporary storage - **NOT recommended for production** (keypair lost on pod restart)

#### Secret-Based Keypair Storage (Recommended)

Secret-based storage (`persistence.keypair.type: secret`) provides several advantages:

- **Production-ready**: Integrates with external secret managers (Vault, AWS Secrets Manager, etc.)
- **GitOps-friendly**: Works with Sealed Secrets, SOPS, or other encryption tools
- **Easy key rotation**: Update secrets centrally and restart pods to pick up new keys
- **Stateless-compatible**: Works with all deployment patterns (StatefulSet, DaemonSet, Deployment)

##### Secret Naming Convention

Each replica requires its own secret following this naming pattern:
```
{{ .Release.Name }}-{{ replica-index }}-secret
```

Examples:
- Replica 0: `kagent-0-secret`
- Replica 1: `kagent-1-secret`
- Replica 2: `kagent-2-secret`

Each secret must contain exactly two keys:
- `private_key.pem`: Ed25519 private key (PEM format)
- `public_key.pem`: Ed25519 public key (PEM format)

##### Option 1: Generating Keypairs with Helper Script

Use the provided `generate-secrets.sh` script to quickly create ed25519 keypairs:

```bash
# Generate secrets for 3 replicas
./generate-secrets.sh 3

# This creates:
# - generated_secrets/generated_secrets.yaml (Kubernetes secret manifest)
# - generated_secrets/private_key_*.pem (individual keypair files for backup)
# - generated_secrets/public_key_*.pem (individual public keys for backup)

# Apply the secrets before installing the chart
kubectl apply -f generated_secrets/generated_secrets.yaml

# Install kagent (it will automatically use the pre-created secrets)
helm install kagent . \
  --set deploymentType=statefulset \
  --set replicaCount=3

# For custom release name
RELEASE_NAME=my-kagent ./generate-secrets.sh 3
kubectl apply -f generated_secrets/generated_secrets.yaml
helm install my-kagent . --set replicaCount=3
```

**Important**: Keep the generated PEM files in `generated_secrets/` directory as backups. Store them securely (e.g., password-protected archive, secret management system).

#### Using PVC for Keypair Storage

If you prefer PersistentVolumeClaims for keypairs instead of secrets:

```bash
# StatefulSet with PVC-based keypair storage
helm install kagent . \
  --set deploymentType=statefulset \
  --set persistence.keypair.type=pvc
```

#### Using hostPath for Keypair Storage (DaemonSet)

For DaemonSet deployments with node-local keypair storage:

```bash
# DaemonSet pattern with hostPath keypairs
helm install kagent . \
  --set deploymentType=daemonset \
  --set persistence.keypair.enabled=true \
  --set persistence.keypair.type=hostPath \
  --set persistence.keypair.hostPath.path=/var/lib/kagent/keys
```

##### Option 2: Integration with External Secret Managers

For production environments, integrate with external secret managers to avoid storing sensitive keypairs in Git:

###### External Secrets Operator (ESO)

[External Secrets Operator](https://external-secrets.io/) syncs secrets from external providers to Kubernetes Secrets.

**Prerequisites**:
1. Install External Secrets Operator in your cluster
2. Configure a SecretStore for your provider

**AWS Secrets Manager Example**:

```bash
# 1. Store keypairs in AWS Secrets Manager (do this for each replica)
aws secretsmanager create-secret \
  --name kagent/keypairs/replica-0 \
  --description "Kagent replica 0 ed25519 keypair" \
  --secret-string "{\"private_key\":\"$(cat generated_secrets/private_key_0.pem)\",\"public_key\":\"$(cat generated_secrets/public_key_0.pem)\"}"

# Repeat for replica-1, replica-2, etc.
```

Create ExternalSecret resources:

```yaml
# external-secrets.yaml
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: kagent-0-keypair
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: kagent-0-secret
    creationPolicy: Owner
  data:
  - secretKey: private_key.pem
    remoteRef:
      key: kagent/keypairs/replica-0
      property: private_key
  - secretKey: public_key.pem
    remoteRef:
      key: kagent/keypairs/replica-0
      property: public_key
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: kagent-1-keypair
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: kagent-1-secret
    creationPolicy: Owner
  data:
  - secretKey: private_key.pem
    remoteRef:
      key: kagent/keypairs/replica-1
      property: private_key
  - secretKey: public_key.pem
    remoteRef:
      key: kagent/keypairs/replica-1
      property: public_key
---
# Repeat for each replica...
```

Deploy and install:
```bash
# Apply ExternalSecret resources (creates the kubernetes secrets)
kubectl apply -f external-secrets.yaml

# Wait for secrets to be created
kubectl wait --for=condition=Ready externalsecret/kagent-0-keypair --timeout=60s

# Install kagent
helm install kagent . \
  --set deploymentType=statefulset \
  --set replicaCount=2 \
  --set persistence.keypair.type=secret
```

**Google Cloud Secret Manager Example**:

```bash
# 1. Store in GCP Secret Manager
gcloud secrets create kagent-replica-0-private \
  --data-file=generated_secrets/private_key_0.pem

gcloud secrets create kagent-replica-0-public \
  --data-file=generated_secrets/public_key_0.pem

# 2. Create ExternalSecret
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: kagent-0-keypair
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcpsm-secret-store
    kind: SecretStore
  target:
    name: kagent-0-secret
  data:
  - secretKey: private_key.pem
    remoteRef:
      key: kagent-replica-0-private
  - secretKey: public_key.pem
    remoteRef:
      key: kagent-replica-0-public
EOF
```

**Azure Key Vault Example**:

```bash
# 1. Store in Azure Key Vault
az keyvault secret set \
  --vault-name my-keyvault \
  --name kagent-replica-0-private \
  --file generated_secrets/private_key_0.pem

az keyvault secret set \
  --vault-name my-keyvault \
  --name kagent-replica-0-public \
  --file generated_secrets/public_key_0.pem

# 2. Create ExternalSecret
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: kagent-0-keypair
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-keyvault
    kind: SecretStore
  target:
    name: kagent-0-secret
  data:
  - secretKey: private_key.pem
    remoteRef:
      key: kagent-replica-0-private
  - secretKey: public_key.pem
    remoteRef:
      key: kagent-replica-0-public
EOF
```

###### HashiCorp Vault

Use the [Vault Secrets Operator](https://github.com/hashicorp/vault-secrets-operator) or [vault-csi-provider](https://github.com/hashicorp/vault-csi-provider):

**Vault KV Secrets Example**:

```bash
# 1. Store keypairs in Vault KV store
vault kv put secret/kagent/replica-0 \
  private_key="$(cat generated_secrets/private_key_0.pem)" \
  public_key="$(cat generated_secrets/public_key_0.pem)"

# 2. Create VaultStaticSecret (using Vault Secrets Operator)
cat <<EOF | kubectl apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: kagent-0-keypair
spec:
  vaultAuthRef: vault-auth
  mount: secret
  path: kagent/replica-0
  refreshAfter: 1h
  destination:
    name: kagent-0-secret
    create: true
    transformation:
      templates:
        private_key.pem:
          text: "{{ .Secrets.private_key }}"
        public_key.pem:
          text: "{{ .Secrets.public_key }}"
EOF
```

###### Sealed Secrets (GitOps)

Use [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) to encrypt secrets for safe Git storage:

```bash
# 1. Generate keypairs using the helper script
./generate-secrets.sh 3

# 2. Create individual secrets and seal them
for i in 0 1 2; do
  kubectl create secret generic kagent-${i}-secret \
    --from-file=private_key.pem=generated_secrets/private_key_${i}.pem \
    --from-file=public_key.pem=generated_secrets/public_key_${i}.pem \
    --dry-run=client -o yaml | \
  kubeseal -o yaml > kagent-${i}-sealed-secret.yaml
done

# 3. Commit sealed secrets to Git
git add kagent-*-sealed-secret.yaml
git commit -m "Add kagent sealed secrets"

# 4. Apply sealed secrets (via GitOps or manually)
kubectl apply -f kagent-0-sealed-secret.yaml
kubectl apply -f kagent-1-sealed-secret.yaml
kubectl apply -f kagent-2-sealed-secret.yaml

# 5. Install kagent (sealed-secrets controller will create the actual secrets)
helm install kagent . \
  --set deploymentType=statefulset \
  --set replicaCount=3 \
  --set persistence.keypair.type=secret
```

###### SOPS (Encrypted Files in Git)

Use [SOPS](https://github.com/mozilla/sops) with age, GPG, or cloud KMS:

```bash
# 1. Generate keypairs
./generate-secrets.sh 3

# 2. Encrypt the generated secret manifest
sops --encrypt --age <your-age-public-key> \
  generated_secrets/generated_secrets.yaml > \
  generated_secrets/generated_secrets.enc.yaml

# 3. Commit encrypted file to Git
git add generated_secrets/generated_secrets.enc.yaml
git commit -m "Add encrypted kagent secrets"

# 4. Decrypt and apply (in CI/CD or locally)
sops --decrypt generated_secrets/generated_secrets.enc.yaml | kubectl apply -f -

# 5. Install kagent
helm install kagent . --set replicaCount=3
```

**Important Notes**:
- When using `persistence.keypair.type: secret`, secrets must exist **before** installing the chart
- Each secret must contain both `private_key.pem` and `public_key.pem` keys
- Secret names must follow the pattern: `{{ .Release.Name }}-{{ replica-index }}-secret`
- For custom release names, ensure secret names match (e.g., `my-agent-0-secret`, `my-agent-1-secret`)
- **Never commit unencrypted keypairs to Git** - always use encryption (Sealed Secrets, SOPS) or external secret managers

#### Using PVC for Keypair Storage

If you prefer PersistentVolumeClaims for keypairs instead of secrets:

```bash
# StatefulSet with PVC-based keypair storage
helm install kagent . \
  --set deploymentType=statefulset \
  --set persistence.keypair.type=pvc
```

#### Using hostPath for Keypair Storage (DaemonSet)

For DaemonSet deployments with node-local keypair storage:

```bash
# DaemonSet pattern with hostPath keypairs
helm install kagent . \
  --set deploymentType=daemonset \
  --set persistence.keypair.enabled=true \
  --set persistence.keypair.type=hostPath \
  --set persistence.keypair.hostPath.path=/var/lib/kagent/keys
```

### Network Policies

Enable network policies to restrict egress traffic:

```yaml
networkPolicy:
  enabled: true
  egress:
    # DNS
    - to:
      - namespaceSelector: {}
      ports:
      - protocol: UDP
        port: 53
    # Kentik API
    - to:
      - ipBlock:
          cidr: 0.0.0.0/0
      ports:
      - protocol: TCP
        port: 443
    # SNMP (adjust CIDR for your network)
    - to:
      - ipBlock:
          cidr: 10.0.0.0/8
      ports:
      - protocol: UDP
        port: 161
```

### Custom ConfigMap

For advanced configuration overrides:

```yaml
configmap:
  enabled: true
  data:
    K_CUSTOM_SETTING: "value"
    K_ANOTHER_SETTING: "value2"
```

**Note**: Environment variables take precedence over ConfigMap values.

## Upgrade Strategy

### Within Same Pattern

Upgrades within the same deployment pattern are supported:

```bash
# Upgrade StatefulSet pattern
helm upgrade kagent . \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN \
  --set replicaCount=3

# Upgrade with new image version
helm upgrade kagent . \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN \
  --set image.tag=v4.2.0
```

### Changing Configuration

```bash
# Update log level
helm upgrade kagent . \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN \
  --set kagent.logLevel=debug

# Update release channel
helm upgrade kagent . \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN \
  --set kagent.releaseChannel=beta
```

### Refreshing an Expired Provisioning Token

If the provisioning token expires, upgrade with the new token and restart pods:

```bash
helm upgrade kagent . \
  --set-string kagent.companyId=YOUR_COMPANY_ID \
  --set-string kagent.provisioningToken=NEW_REFRESHED_TOKEN

# Pods must be restarted to pick up the new token value
kubectl rollout restart statefulset/kagent
# or for daemonset:
kubectl rollout restart daemonset/kagent
```

## Values Schema

For complete field definitions and validation, see [contracts/values.schema.json](contracts/values.schema.json).

## Development

### Linting

```bash
helm lint .
```

### Template Rendering

```bash

# Render StatefulSet pattern
helm template kagent . \
  --set-string kagent.companyId=123 \
  --set-string kagent.provisioningToken=tok \
  --set deploymentType=statefulset

# Render DaemonSet pattern
helm template kagent . \
  --set-string kagent.companyId=123 \
  --set-string kagent.provisioningToken=tok \
  --set deploymentType=daemonset

# Render OpenShift-compatible StatefulSet pattern
helm template kagent . \
  --set-string kagent.companyId=test-company \
  --set-string kagent.provisioningToken=tok \
  --set openshift.enabled=true
```

### Testing

```bash
# Dry run install
helm install kagent . --dry-run --debug \
  --set-string kagent.companyId=123 \
  --set-string kagent.provisioningToken=tok
```

## Support

- Documentation: https://github.com/kentik/kagent-helm
- Issues: https://github.com/kentik/kagent-helm/issues
- Kentik Support: support@kentik.com

## License

Copyright © 2025 Kentik
