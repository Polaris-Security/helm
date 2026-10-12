{{- define "assetDiscovery.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "assetDiscovery.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "assetDiscovery.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "assetDiscovery.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "assetDiscovery.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
"token" or "kubernetes": which credential the pod presents. See values.yaml polaris.auth.
*/}}
{{- define "assetDiscovery.authMode" -}}
{{- $mode := .Values.polaris.auth | default "auto" -}}
{{- if eq $mode "auto" -}}
{{- if or .Values.polaris.apiToken .Values.polaris.existingSecret -}}token{{- else -}}kubernetes{{- end -}}
{{- else if has $mode (list "token" "kubernetes") -}}
{{- $mode -}}
{{- else -}}
{{- fail "polaris.auth must be auto, token or kubernetes" -}}
{{- end -}}
{{- end -}}

{{- define "assetDiscovery.tokenSecretName" -}}
{{- default (printf "%s-token" (include "assetDiscovery.fullname" .)) .Values.polaris.existingSecret -}}
{{- end -}}
