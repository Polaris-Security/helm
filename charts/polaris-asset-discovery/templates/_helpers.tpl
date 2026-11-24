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

{{/*
Edge Devices: the device list the agent reads (EDGE_DEVICES_FILE), as JSON. Each device's
credentials are mounted from its existingSecret at /secrets/edge-devices/<index>, its CA
at /secrets/edge-devices/<index>-ca. Fails on an entry the agent would refuse.
*/}}
{{- define "assetDiscovery.edgeDevicesJson" -}}
{{- $out := list -}}
{{- $seen := dict -}}
{{- range $i, $d := .Values.edgeDevices -}}
{{- $where := printf "edgeDevices[%d]" $i -}}
{{- $id := required (printf "%s.id is required" $where) $d.id | toString -}}
{{- if hasKey $seen $id -}}{{- fail (printf "edgeDevices: id %s is listed twice" $id) -}}{{- end -}}
{{- $_ := set $seen $id true -}}
{{- $kind := required (printf "%s.kind is required" $where) $d.kind | toString | lower -}}
{{- $_ := required (printf "%s.url is required" $where) $d.url -}}
{{- $_ := required (printf "%s.existingSecret is required" $where) $d.existingSecret -}}
{{- $dir := printf "/secrets/edge-devices/%d" $i -}}
{{- $entry := dict "id" $id "kind" $kind "name" ($d.name | default $id | toString) "url" ($d.url | toString) -}}
{{- if eq $kind "netscaler" -}}
{{- $_ := set $entry "username_file" (printf "%s/username" $dir) -}}
{{- $_ := set $entry "password_file" (printf "%s/password" $dir) -}}
{{- else if eq $kind "bunkerweb" -}}
{{- $_ := set $entry "token_file" (printf "%s/token" $dir) -}}
{{- else -}}
{{- fail (printf "%s.kind must be netscaler or bunkerweb (got %s)" $where $kind) -}}
{{- end -}}
{{- if $d.caSecret -}}
{{- $_ := set $entry "verify_tls" (printf "/secrets/edge-devices/%d-ca/ca.pem" $i) -}}
{{- else -}}
{{- $_ := set $entry "verify_tls" (ternary true $d.verifyTls (kindIs "invalid" $d.verifyTls)) -}}
{{- end -}}
{{- $out = append $out $entry -}}
{{- end -}}
{{- toPrettyJson $out -}}
{{- end -}}
