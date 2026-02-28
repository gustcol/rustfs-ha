{{/*
Expand the name of the chart.
*/}}
{{- define "rustfs.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "rustfs.fullname" -}}
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
{{- define "rustfs.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rustfs.labels" -}}
helm.sh/chart: {{ include "rustfs.chart" . }}
{{ include "rustfs.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rustfs.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rustfs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "rustfs.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "rustfs.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the secret name
*/}}
{{- define "rustfs.secretName" -}}
{{- if .Values.secret.existingSecret }}
{{- .Values.secret.existingSecret }}
{{- else }}
{{- printf "%s-secret" (include "rustfs.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Return image pull secret content
*/}}
{{- define "imagePullSecret" }}
{{- with .Values.imageRegistryCredentials }}
{{- printf "{\"auths\":{\"%s\":{\"username\":\"%s\",\"password\":\"%s\",\"email\":\"%s\",\"auth\":\"%s\"}}}" .registry .username .password .email (printf "%s:%s" .username .password | b64enc) | b64enc }}
{{- end }}
{{- end }}

{{/*
Return the default imagePullSecret name
*/}}
{{- define "rustfs.imagePullSecret.name" -}}
{{- printf "%s-registry-secret" (include "rustfs.fullname" .) }}
{{- end }}

{{/*
Render imagePullSecrets for workloads - appends registry secret
*/}}
{{- define "chart.imagePullSecrets" -}}
{{- $secrets := .Values.imagePullSecrets | default list }}
{{- if .Values.imageRegistryCredentials.enabled }}
{{- $secrets = append $secrets (dict "name" (include "rustfs.imagePullSecret.name" .)) }}
{{- end }}
{{- toYaml $secrets }}
{{- end }}

{{/*
Return the number of drives (data volumes) per node.
Uses .Values.drivesPerNode if explicitly set.
Falls back to replicaCount for backward compatibility with the legacy 4-replica layout.
For single-drive-per-node setups, returns 1.
*/}}
{{- define "rustfs.drivesPerNode" -}}
{{- if .Values.drivesPerNode }}
{{- .Values.drivesPerNode | int }}
{{- else if le (int .Values.replicaCount) 4 }}
{{- .Values.replicaCount | int }}
{{- else }}
{{- 1 }}
{{- end }}
{{- end }}

{{/*
Render RUSTFS_VOLUMES for distributed mode.
Generates the volume URL string for peer discovery using DNS-based service discovery.
Supports any replica count and drives-per-node configuration.
*/}}
{{- define "rustfs.volumes" -}}

{{- $protocol := "http" -}}
{{- if .Values.mtls.enabled -}}
  {{- $protocol = "https" -}}
{{- end -}}

{{- $fullname := include "rustfs.fullname" . -}}
{{- $namespace := .Release.Namespace -}}
{{- $port := .Values.service.endpoint.port | int -}}
{{- $replicas := .Values.replicaCount | int -}}
{{- $drivesPerNode := include "rustfs.drivesPerNode" . | int -}}

{{- if gt $drivesPerNode 1 }}
{{- printf "%s://%s-{0...%d}.%s-headless.%s.svc.cluster.local:%d/data/rustfs{0...%d}" $protocol $fullname (sub $replicas 1) $fullname $namespace $port (sub $drivesPerNode 1) }}
{{- else }}
{{- printf "%s://%s-{0...%d}.%s-headless.%s.svc.cluster.local:%d/data" $protocol $fullname (sub $replicas 1) $fullname $namespace $port }}
{{- end }}
{{- end }}

{{/*
Render RUSTFS_SERVER_DOMAINS
*/}}

{{- define "rustfs.serverDomains" -}}
{{- $domains := list .Values.config.rustfs.domains -}}
{{- $fullname := include "rustfs.fullname" . -}}
{{- $replicaCount := int .Values.replicaCount -}}
{{- $servicePort := .Values.service.endpoint.port | default 9000 -}}
{{- range $i := until $replicaCount -}}
  {{- $podDomain := printf "%s-%d.%s-headless:%d" $fullname $i $fullname (int $servicePort) -}}
  {{- $domains = append $domains $podDomain -}}
{{- end -}}
{{- join "," $domains -}}
{{- end -}}
