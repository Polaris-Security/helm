{{/*
Resource names are intentionally stable literals ("backend", "frontend", "backend-config",
"ollama-embed") rather than release-prefixed. The backend reaches the embedder at
http://ollama-embed:11434 and the Ingress routes to `backend`/`frontend` by name, so these
are part of the platform's in-cluster contract, not cosmetic. One release per namespace.
*/}}

{{/*
Name of the Secret that supplies the backend's environment variables.

The chart does not create this Secret — the operator brings it (ExternalSecret,
sealed-secret, SOPS, or plain `kubectl create secret generic`). It is mounted with
envFrom by every pod that runs the backend image (web, migrate init container,
celery-worker, celery-beat) and read by the celery-exporter for the broker URL.
*/}}
{{- define "polaris.backendSecretName" -}}
{{- required "backend.existingSecret must be set to the name of the Secret holding the backend environment" .Values.backend.existingSecret -}}
{{- end -}}

{{/*
Name of the Secret holding the Postgres connection URI. Defaults to the "<cluster>-app"
Secret CloudNativePG generates for the owner role; overridable for a bring-your-own
database.
*/}}
{{- define "polaris.databaseSecretName" -}}
{{- if .Values.postgres.urlSecret.name -}}
{{- .Values.postgres.urlSecret.name -}}
{{- else if .Values.postgres.enabled -}}
{{- printf "%s-app" .Values.postgres.cluster.name -}}
{{- else -}}
{{- fail "postgres.enabled is false, so postgres.urlSecret.name must name a Secret containing a Postgres connection URI" -}}
{{- end -}}
{{- end -}}

{{/*
Hostnames Django accepts requests for. Defaults to the Ingress hosts and the in-cluster
Service DNS name, so a hostname is normally declared exactly once.
*/}}
{{- define "polaris.allowedHosts" -}}
{{- if .Values.backend.allowedHosts -}}
{{- join "," .Values.backend.allowedHosts -}}
{{- else -}}
{{- $hosts := concat (.Values.ingress.hosts | default list) (list (printf "backend.%s.svc.cluster.local" .Release.Namespace)) -}}
{{- join "," $hosts -}}
{{- end -}}
{{- end -}}

{{/*
Origins trusted for CSRF. Defaults to https://<host> for each Ingress host.
*/}}
{{- define "polaris.csrfTrustedOrigins" -}}
{{- if .Values.backend.csrfTrustedOrigins -}}
{{- join "," .Values.backend.csrfTrustedOrigins -}}
{{- else -}}
{{- $origins := list -}}
{{- range .Values.ingress.hosts | default list -}}
{{- $origins = append $origins (printf "https://%s" .) -}}
{{- end -}}
{{- join "," $origins -}}
{{- end -}}
{{- end -}}

{{/*
The backend-config ConfigMap contents: derived keys first, then backend.config, then
backend.extraConfig — so a user's extraConfig always wins.
*/}}
{{- define "polaris.backendConfig" -}}
{{- $derived := dict
      "ALLOWED_HOSTS" (include "polaris.allowedHosts" .)
      "CSRF_TRUSTED_ORIGINS" (include "polaris.csrfTrustedOrigins" .)
      "POSTHOG_HOST" .Values.posthog.host -}}
{{- if .Values.assetDiscovery.enabled -}}
{{- /* Which Kubernetes service account may post Discovery Reports with its own token. */ -}}
{{- $_ := set $derived "ASSET_DISCOVERY_KUBERNETES_SERVICE_ACCOUNTS" (include "polaris.assetDiscoveryServiceAccount" .) -}}
{{- /* The audience the subchart mints its projected token for; the two must match. */ -}}
{{- $discovery := .Values.assetDiscovery.polaris | default dict -}}
{{- $_ := set $derived "ASSET_DISCOVERY_KUBERNETES_AUDIENCE" ($discovery.tokenAudience | default "polaris-asset-discovery") -}}
{{- end -}}
{{- $config := merge (deepCopy (.Values.backend.extraConfig | default dict)) (deepCopy (.Values.backend.config | default dict)) $derived -}}
{{- range $key, $value := $config }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- end -}}

{{/*
Environment shared by every pod running the backend image. The DATABASE_URL Secret is
read directly rather than via envFrom because only one key of it is wanted.
*/}}
{{- define "polaris.backendEnv" -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "polaris.databaseSecretName" . }}
      key: {{ .Values.postgres.urlSecret.key }}
{{- end -}}

{{/*
Image reference for the backend image, shared by web/worker/beat.
*/}}
{{- define "polaris.backendImage" -}}
{{ .Values.backend.image.repository }}:{{ required "backend.image.tag must be set" .Values.backend.image.tag }}
{{- end -}}

{{/*
Pod-level settings shared by every workload: image pull secrets, the component's pod
security context and its scheduling directives. Each block is omitted when unset, and the whole include collapses
to nothing when none apply.

Usage: {{- with (include "polaris.podSpec" (dict "root" . "component" .Values.frontend) | trim) }}
       {{- nindent 6 . }}
       {{- end }}
*/}}
{{- define "polaris.podSpec" -}}
{{- with .root.Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .component.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .component.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .component.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .component.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
"<namespace>:<name>" of the Asset Discovery subchart's service account. The subchart names
it after its fullnameOverride, which values.yaml fixes for exactly this reason.
*/}}
{{- define "polaris.assetDiscoveryServiceAccount" -}}
{{- $sa := .Values.assetDiscovery.serviceAccount | default dict -}}
{{- printf "%s:%s" .Release.Namespace (default .Values.assetDiscovery.fullnameOverride $sa.name) -}}
{{- end -}}

{{/*
The backend web pod's ServiceAccount: its own when Asset Discovery needs it to create
TokenReviews, else the namespace default as before.
*/}}
{{- define "polaris.backendServiceAccount" -}}
{{- if .Values.assetDiscovery.enabled -}}backend{{- end -}}
{{- end -}}

{{/*
GeoLite2-ASN provisioning (geoip.*). When enabled, the backend web and celery-worker pods
get an init container that downloads the database once into a shared emptyDir, so it is
there before Django starts, and a sidecar that refreshes it every geoip.frequencyHours.
The app container mounts the volume read-only and is pointed at the file with
PERIMETER_DEFENCE_GEOLITE2_ASN_PATH, and at GeoLite2-City (when geoip.editionIds lists it)
with IDENTITY_DEFENCE_GEOLITE2_CITY_PATH. Each snippet renders nothing when geoip is
disabled.
*/}}

{{/*
Secret holding the MaxMind account ID and license key: geoip.existingSecret, else the
backend's own Secret. Only the two keys are read, never the whole Secret.
*/}}
{{- define "polaris.geoip.secretName" -}}
{{- .Values.geoip.existingSecret | default (include "polaris.backendSecretName" .) -}}
{{- end -}}

{{/*
Path of the GeoLite2-ASN database inside every container that mounts the volume. Fails
the render when geoip.editionIds does not download GeoLite2-ASN, since the backend would
then be pointed at a file that never appears.
*/}}
{{- define "polaris.geoip.asnPath" -}}
{{- if not (has "GeoLite2-ASN" (splitList " " .Values.geoip.editionIds)) -}}
{{- fail "geoip.editionIds must include GeoLite2-ASN (space-separated edition IDs)" -}}
{{- end -}}
{{- printf "%s/GeoLite2-ASN.mmdb" (trimSuffix "/" .Values.geoip.mountPath) -}}
{{- end -}}

{{/*
A geoipupdate container. `frequency` 0 runs once and exits (the init container); N > 0
re-runs every N hours (the sidecar).

Both fail open. The image's own entrypoint exits on a failed download (`set -e`), which
would block the init container and crash-loop the sidecar, taking the pod out of the
Service. So geoipupdate is run directly: a failed download is logged, the init container
still succeeds, and the sidecar retries hourly until it gets through. The backend reopens
the file when it appears or changes, and clusters by prefix only until then. The Secret
keys are optional for the same reason: without them the download fails, the pod does not.

Usage: {{- include "polaris.geoip.container" (dict "root" . "name" "geoip-init" "frequency" 0) | nindent 8 }}
*/}}
{{- define "polaris.geoip.container" -}}
{{- $geoip := .root.Values.geoip -}}
- name: {{ .name }}
  image: "{{ $geoip.image.repository }}:{{ required "geoip.image.tag must be set" $geoip.image.tag }}"
  {{- with $geoip.image.pullPolicy }}
  imagePullPolicy: {{ . }}
  {{- end }}
  command: ["/bin/sh", "-c"]
  args:
    - |
      {{- if eq (int .frequency) 0 }}
      /usr/bin/geoipupdate --output || echo "geoipupdate: download failed; starting without GeoLite2 (the sidecar retries)" >&2
      {{- else }}
      trap 'exit 0' TERM INT
      while true; do
        if /usr/bin/geoipupdate --output; then
          delay={{ mul (int .frequency) 3600 }}
        else
          echo "geoipupdate: download failed; retrying in 1h" >&2
          delay=3600
        fi
        sleep "$delay" & wait $!
      done
      {{- end }}
  env:
    - name: GEOIPUPDATE_ACCOUNT_ID
      valueFrom:
        secretKeyRef:
          name: {{ include "polaris.geoip.secretName" .root }}
          key: {{ $geoip.accountIdKey }}
          optional: true
    - name: GEOIPUPDATE_LICENSE_KEY
      valueFrom:
        secretKeyRef:
          name: {{ include "polaris.geoip.secretName" .root }}
          key: {{ $geoip.licenseKeyKey }}
          optional: true
    - name: GEOIPUPDATE_EDITION_IDS
      value: {{ $geoip.editionIds | quote }}
    - name: GEOIPUPDATE_CONF_FILE
      value: ""
    - name: GEOIPUPDATE_DB_DIR
      value: {{ $geoip.mountPath | quote }}
  {{- with $geoip.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $geoip.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: geoip
      mountPath: {{ $geoip.mountPath }}
{{- end -}}

{{/* The one-shot download that runs before the app container starts. */}}
{{- define "polaris.geoip.initContainer" -}}
{{- if .Values.geoip.enabled -}}
{{ include "polaris.geoip.container" (dict "root" . "name" "geoip-init" "frequency" 0) }}
{{- end -}}
{{- end -}}

{{/* The refreshing sidecar. geoip.frequencyHours: 0 ⇒ none, the init download only. */}}
{{- define "polaris.geoip.sidecar" -}}
{{- if and .Values.geoip.enabled (gt (int .Values.geoip.frequencyHours) 0) -}}
{{ include "polaris.geoip.container" (dict "root" . "name" "geoipupdate" "frequency" (int .Values.geoip.frequencyHours)) }}
{{- end -}}
{{- end -}}

{{/* Env entry pointing the backend at the database. */}}
{{- define "polaris.geoip.appEnv" -}}
{{- if .Values.geoip.enabled -}}
- name: PERIMETER_DEFENCE_GEOLITE2_ASN_PATH
  value: {{ include "polaris.geoip.asnPath" . | quote }}
{{- if has "GeoLite2-City" (splitList " " .Values.geoip.editionIds) }}
- name: IDENTITY_DEFENCE_GEOLITE2_CITY_PATH
  value: {{ printf "%s/GeoLite2-City.mmdb" (trimSuffix "/" .Values.geoip.mountPath) | quote }}
{{- end }}
{{- end -}}
{{- end -}}

{{/* The app container's read-only mount of the database volume. */}}
{{- define "polaris.geoip.appVolumeMount" -}}
{{- if .Values.geoip.enabled -}}
- name: geoip
  mountPath: {{ .Values.geoip.mountPath }}
  readOnly: true
{{- end -}}
{{- end -}}

{{/* The shared volume the init container, sidecar and app container all mount. */}}
{{- define "polaris.geoip.volume" -}}
{{- if .Values.geoip.enabled -}}
- name: geoip
  emptyDir: {}
{{- end -}}
{{- end -}}
