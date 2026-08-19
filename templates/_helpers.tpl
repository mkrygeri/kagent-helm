{{/*
Expand the name of the chart.
*/}}
{{- define "kagent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "kagent.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "kagent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kagent.labels" -}}
helm.sh/chart: {{ include "kagent.chart" . }}
{{ include "kagent.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kagent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kagent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "kagent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kagent.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the OpenShift SecurityContextConstraints to use
*/}}
{{- define "kagent.openshiftSccName" -}}
{{- default (printf "%s-scc" (include "kagent.fullname" .)) .Values.openshift.securityContextConstraints.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Validate all chart configuration
*/}}
{{- define "kagent.validate" -}}
{{- /* Validate deployment type */ -}}
{{- $validTypes := list "statefulset" "daemonset" }}
{{- if not (has .Values.deploymentType $validTypes) }}
{{- fail (printf "Invalid deploymentType '%s'. Must be one of: statefulset, daemonset" .Values.deploymentType) }}
{{- end }}
{{- /* Validate required kagent configuration */ -}}
{{- if not (.Values.kagent.companyId | toString | trim) }}
{{- fail "kagent.companyId is required. Provide via: --set-string kagent.companyId=YOUR_COMPANY_ID\nGet your company ID from the Kentik Portal (Settings → Company)" }}
{{- end }}
{{- if not (.Values.kagent.provisioningToken | toString | trim) }}
{{- fail "kagent.provisioningToken is required. Provide via: --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN" }}
{{- end }}
{{- /* Validate replica count for statefulset */ -}}
{{- if eq .Values.deploymentType "statefulset" }}
{{- if not .Values.replicaCount }}
{{- fail (printf "replicaCount is required for deploymentType '%s'. Provide via: --set replicaCount=N" .Values.deploymentType) }}
{{- end }}
{{- if lt (int .Values.replicaCount) 1 }}
{{- fail (printf "replicaCount must be at least 1 for deploymentType '%s', got: %d" .Values.deploymentType (int .Values.replicaCount)) }}
{{- end }}
{{- end }}
{{- /* Validate persistence type for daemonset */ -}}
{{- if eq .Values.deploymentType "daemonset" }}
{{- if .Values.persistence.enabled }}
{{- if and (ne .Values.persistence.type "hostPath") (ne .Values.persistence.type "emptyDir") }}
{{- fail (printf "DaemonSet deployments only support 'hostPath' or 'emptyDir' for persistence.type, got: '%s'. Set persistence.type=hostPath for persistent storage." .Values.persistence.type) }}
{{- end }}
{{- if .Values.persistence.keypair.enabled }}
{{- if and (ne .Values.persistence.keypair.type "hostPath") (ne .Values.persistence.keypair.type "emptyDir") }}
{{- fail (printf "DaemonSet deployments only support 'hostPath' or 'emptyDir' for persistence.keypair.type, got: '%s'." .Values.persistence.keypair.type) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Pod security context with OpenShift restricted SCC compatibility
*/}}
{{- define "kagent.podSecurityContext" -}}
{{- if and .Values.openshift.enabled .Values.openshift.restrictedSecurityContext }}
{{- $podSecurityContext := omit .Values.podSecurityContext "runAsUser" "runAsGroup" "fsGroup" -}}
{{- $_ := set $podSecurityContext "seccompProfile" (dict "type" "RuntimeDefault") -}}
{{- toYaml $podSecurityContext }}
{{- else }}
{{- toYaml .Values.podSecurityContext }}
{{- end }}
{{- end }}

{{/*
Container security context with OpenShift restricted SCC compatibility
*/}}
{{- define "kagent.securityContext" -}}
{{- $securityContext := deepCopy .Values.securityContext -}}
{{- if and .Values.openshift.enabled .Values.openshift.restrictedSecurityContext }}
{{- $capabilities := deepCopy ($securityContext.capabilities | default dict) -}}
{{- $_ := unset $capabilities "add" -}}
{{- $_ := set $securityContext "capabilities" $capabilities -}}
{{- end }}
{{- toYaml $securityContext }}
{{- end }}

{{/*
Kagent container definition (shared across deployment types)
*/}}
{{- define "kagent.container" -}}
{{- $lp := .Values.livenessProbe | default dict }}
{{- $rp := .Values.readinessProbe | default dict }}
{{- $hc := .Values.kagent.healthCheck | default dict }}
{{- $healthEnabled := or $hc.enabled $lp.enabled $rp.enabled .Values.service.enabled }}
{{- $healthPort := (($lp.httpGet | default dict).port | default ($rp.httpGet | default dict).port | default $hc.port | default 8099 | int) }}
- name: kagent
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  env:
  # Required: Company ID for agent scoping
  - name: K_COMPANY_ID
    value: {{ required "kagent.companyId is required" .Values.kagent.companyId | quote }}
  # Required: Provisioning token (injected via Secret)
  - name: K_REGISTER_PROVISIONING_TOKEN
    valueFrom:
      secretKeyRef:
        name: {{ include "kagent.fullname" . }}-provisioning-token
        key: token
  # Core configuration
  - name: K_API_ROOT
    value: {{ .Values.kagent.apiEndpoint | default "grpc.api.kentik.com:443" | quote }}
  - name: K_RELEASE_CHANNEL
    value: {{ .Values.kagent.releaseChannel | default "stable" | quote }}
  - name: K_LOG_LEVEL
    value: {{ .Values.kagent.logLevel | default "info" | quote }}
  - name: K_LOG_DEST
    value: {{ .Values.kagent.logDest | default "stdout" | quote }}
  - name: K_ROOT
    value: "/opt/kentik"
  - name: K_KEYS_DIRECTORY
    value: "/opt/ua/keys"
  - name: K_K8S_HELM
    value: "true"
  # Health check server configuration (auto-enabled when probes are enabled)
  {{- if $healthEnabled }}
  - name: K_HC_SERVER_ENABLED
    value: "true"
  - name: K_HC_SERVER_NETWORK
    value: {{ $hc.network | default "tcp4" | quote }}
  - name: K_HC_SERVER_ADDRESS
    value: {{ $hc.address | default (printf ":%d" $healthPort) | quote }}
  {{- end }}
  # Disk space reservation
  - name: K_DISK_SPACE_RESERVATION_ENABLED
    value: {{ .Values.kagent.diskReservation.enabled | default "true" | quote }}
  {{- if .Values.kagent.diskReservation.enabled }}
  - name: K_DISK_SPACE_RESERVATION_INITIAL_SIZE
    value: {{ .Values.kagent.diskReservation.initialSize | quote }}
  {{- end }}
  {{- if .Values.configmap.enabled }}
  # Additional config from ConfigMap
  envFrom:
  - configMapRef:
      name: {{ include "kagent.fullname" . }}-config
  {{- end }}
  {{- include "kagent.volumeMounts" . | nindent 2 }}
  {{- if or $healthEnabled .Values.extraContainerPorts }}
  ports:
  {{- if $healthEnabled }}
  - name: health
    containerPort: {{ $healthPort }}
    protocol: TCP
  {{- end }}
  {{- with .Values.extraContainerPorts }}
    {{- toYaml . | nindent 2 }}
  {{- end }}
  {{- end }}
  securityContext:
    {{- include "kagent.securityContext" . | nindent 4 }}
  resources:
    {{- toYaml .Values.resources | nindent 4 }}
  {{- if $lp.enabled }}
  livenessProbe:
    {{- if $lp.httpGet }}
    httpGet:
      {{- toYaml $lp.httpGet | nindent 6 }}
    {{- end }}
    initialDelaySeconds: {{ $lp.initialDelaySeconds | default 30 }}
    periodSeconds: {{ $lp.periodSeconds | default 10 }}
    timeoutSeconds: {{ $lp.timeoutSeconds | default 5 }}
    failureThreshold: {{ $lp.failureThreshold | default 3 }}
  {{- end }}
  {{- if $rp.enabled }}
  readinessProbe:
    {{- if $rp.httpGet }}
    httpGet:
      {{- toYaml $rp.httpGet | nindent 6 }}
    {{- end }}
    initialDelaySeconds: {{ $rp.initialDelaySeconds | default 5 }}
    periodSeconds: {{ $rp.periodSeconds | default 10 }}
    timeoutSeconds: {{ $rp.timeoutSeconds | default 5 }}
    failureThreshold: {{ $rp.failureThreshold | default 3 }}
  {{- end }}
{{- end }}

{{/*
Pod spec common fields (shared across deployment types)
*/}}
{{- define "kagent.podSpec" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
serviceAccountName: {{ include "kagent.serviceAccountName" . }}
securityContext:
  {{- include "kagent.podSecurityContext" . | nindent 2 }}
containers:
{{- include "kagent.container" . | nindent 0 }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if eq .Values.deploymentType "daemonset" }}
# Default tolerations for control-plane nodes
tolerations:
- key: node-role.kubernetes.io/control-plane
  operator: Exists
  effect: NoSchedule
- key: node-role.kubernetes.io/master
  operator: Exists
  effect: NoSchedule
{{- with .Values.tolerations }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- else }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
{{- $podVolumes := include "kagent.podVolumes" . }}
{{- if $podVolumes }}
volumes:
{{- $podVolumes | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Machine ID feature gate.
Renders "true" only when a stable, identity-scoped /etc/machine-id can be
provided: StatefulSet workload with a Secret-backed keypair (the identity),
where the setup-keypair init container generates the machine-id.
*/}}
{{- define "kagent.machineIdEnabled" -}}
{{- if and (.Values.kagent.machineId | default dict).enabled (eq .Values.deploymentType "statefulset") .Values.persistence.keypair.enabled (eq .Values.persistence.keypair.type "secret") -}}
true
{{- end -}}
{{- end -}}

{{/*
Volume mounts shared across deployment patterns
*/}}
{{- define "kagent.volumeMounts" -}}
volumeMounts:
- name: data
  mountPath: /opt/kentik
{{- if .Values.persistence.keypair.enabled }}
{{- if eq .Values.persistence.keypair.type "secret" }}
- name: keypair-secret
  mountPath: /opt/ua/keys
  readOnly: true
{{- else }}
- name: keys
  mountPath: /opt/ua/keys
{{- end }}
{{- else }}
- name: data
  mountPath: /opt/ua/keys
  subPath: keys
{{- end }}
{{- if include "kagent.machineIdEnabled" . }}
- name: machine-id
  mountPath: /etc/machine-id
  subPath: machine-id
  readOnly: true
{{- end }}
- name: tmp
  mountPath: /tmp
{{- end }}

{{/*
Pod volumes for non-StatefulSet workloads
*/}}
{{- define "kagent.podVolumes" -}}
{{- if ne .Values.deploymentType "statefulset" }}
- name: tmp
  emptyDir: {}
{{- /* Data volume configuration */ -}}
{{- if .Values.persistence.enabled }}
{{- if eq .Values.persistence.type "hostPath" }}
- name: data
  hostPath:
    path: {{ .Values.persistence.hostPath.path }}
    type: {{ .Values.persistence.hostPath.type | default "DirectoryOrCreate" }}
{{- else if eq .Values.persistence.type "pvc" }}
- name: data
  persistentVolumeClaim:
    claimName: {{ include "kagent.fullname" . }}-data
{{- else }}
- name: data
  emptyDir: {}
{{- end }}
{{- else }}
- name: data
  emptyDir: {}
{{- end }}
{{- /* Keypair volume configuration */ -}}
{{- if .Values.persistence.keypair.enabled }}
{{- if eq .Values.persistence.keypair.type "secret" }}
- name: keypair-secret
  secret:
{{/*    Bind first key from Secret as keys volume*/}}
    secretName: {{ include "kagent.fullname" . }}-0-secret
    defaultMode: 0400
{{- else if eq .Values.persistence.keypair.type "hostPath" }}
- name: keys
  hostPath:
    path: {{ .Values.persistence.keypair.hostPath.path }}
    type: {{ .Values.persistence.keypair.hostPath.type | default "DirectoryOrCreate" }}
{{- else if eq .Values.persistence.keypair.type "pvc" }}
- name: keys
  persistentVolumeClaim:
    claimName: {{ include "kagent.fullname" . }}-keys
{{- else }}
- name: keys
  emptyDir: {}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
