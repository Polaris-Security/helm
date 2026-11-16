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
Whether each backend workload mounts its own Secret (backend.secrets.mode=split) rather
than backend.existingSecret whole. Fails on any other mode.
*/}}
{{- define "polaris.secretsSplit" -}}
{{- $mode := .Values.backend.secrets.mode -}}
{{- if eq $mode "split" -}}true
{{- else if ne $mode "legacy" -}}
{{- fail (printf "backend.secrets.mode must be legacy or split, not %q" $mode) -}}
{{- end -}}
{{- end -}}

{{/*
The Secret a backend workload ("web", "worker", "beat", "migrate") mounts with envFrom:
backend.existingSecret in legacy mode, the workload's own in split mode.

Usage: {{ include "polaris.workloadSecretName" (dict "root" . "workload" "web") }}
*/}}
{{- define "polaris.workloadSecretName" -}}
{{- if include "polaris.secretsSplit" .root -}}
{{- $w := index .root.Values.backend.secrets .workload -}}
{{- required (printf "backend.secrets.%s.name must be set in split mode" .workload) $w.name -}}
{{- else -}}
{{- include "polaris.backendSecretName" .root -}}
{{- end -}}
{{- end -}}

{{/*
Credentials that can change accounts in another system, which the web pod must never hold
(Polaris ADR-0159). AUTHENTIK_API_TOKEN is the single admin token the role tokens replace:
where it is the only Authentik token it acts as the response token too.
*/}}
{{- define "polaris.responsePluginKeys" -}}
- AUTHENTIK_API_TOKEN
- AUTHENTIK_RESPONSE_API_TOKEN
- ENTRA_CLIENT_SECRET
- NETBIRD_API_TOKEN
- MAILU_API_TOKEN
- MAILU_DOVEADM_API_KEY
- MAILU_SIEVE_PASSWORD
{{- end -}}

{{/*
The keys a backend workload's Secret holds in split mode: its own list, and for the
default worker the Response Plugin credentials too, while no Response Worker takes them.
Returned as a YAML list. Fails when a workload lacks SECRET_KEY, when web, worker or beat
lack REDIS_URL, or when web lists a Response Plugin credential.
*/}}
{{- define "polaris.workloadKeys" -}}
{{- $s := .root.Values.backend.secrets -}}
{{- $keys := (index $s .workload).keys | default list -}}
{{- if and (eq .workload "worker") (not .root.Values.backend.responseWorker.enabled) -}}
{{- $keys = concat $keys ($s.responseKeys | default list) -}}
{{- end -}}
{{- if not (has "SECRET_KEY" $keys) -}}
{{- fail (printf "backend.secrets.%s.keys must include SECRET_KEY" .workload) -}}
{{- end -}}
{{- if and (has .workload (list "web" "worker" "beat")) (not (has "REDIS_URL" $keys)) -}}
{{- fail (printf "backend.secrets.%s.keys must include REDIS_URL: it is the Celery broker" .workload) -}}
{{- end -}}
{{- if eq .workload "web" -}}
{{- range concat (include "polaris.responsePluginKeys" .root | fromYamlArray) ($s.responseKeys | default list) -}}
{{- if has . $keys -}}
{{- fail (printf "backend.secrets.web.keys lists %s, a Response Plugin credential: the web pod must never hold one (Polaris ADR-0159). Use AUTHENTIK_ENROLLMENT_API_TOKEN for Authentik on web." .) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml (uniq $keys) -}}
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
{{- $hosts := concat (.Values.ingress.hosts | default list) (include "polaris.deviceAccess.publicHosts" . | fromYamlArray) (list (printf "backend.%s.svc.cluster.local" .Release.Namespace)) -}}
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
{{- range concat (.Values.ingress.hosts | default list) (include "polaris.deviceAccess.publicHosts" . | fromYamlArray) -}}
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
{{- if .Values.deviceAccess.enabled -}}
{{- /* Device access (ADR-0155): the backend's own check, and the same "inside" as BunkerWeb. */ -}}
{{- $_ := set $derived "INTERNAL_NETWORKS" (include "polaris.deviceAccess.internalCidrs" .) -}}
{{- $_ := set $derived "DEVICE_ACCESS_MODE" .Values.deviceAccess.mode -}}
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
{{- if .Values.backend.responseWorker.enabled }}
# Routes every task that uses a Response Plugin credential to the `response` queue the
# Response Worker consumes (Polaris ADR-0159). Routes are applied by the sender, so every
# backend pod gets it, and only while a worker consumes that queue.
- name: RESPONSE_QUEUE_ENABLED
  value: "True"
{{- end }}
{{- end -}}

{{/*
The keys the Response Worker's own Secret holds: backend.responseWorker.secret.keys plus
backend.secrets.responseKeys, as a YAML list. Fails when SECRET_KEY or REDIS_URL is
missing, or, where the chart decides what the Secret holds (its ExternalSecret, or split
mode), when it would hold no Response Plugin credential, since it could contain nothing.
*/}}
{{- define "polaris.responseWorkerKeys" -}}
{{- $rw := .Values.backend.responseWorker -}}
{{- $response := .Values.backend.secrets.responseKeys | default list -}}
{{- $keys := concat ($rw.secret.keys | default list) $response -}}
{{- range list "SECRET_KEY" "REDIS_URL" -}}
{{- if not (has . $keys) -}}
{{- fail (printf "backend.responseWorker.secret.keys must include %s" .) -}}
{{- end -}}
{{- end -}}
{{- if and (not $response) (or $rw.externalSecret.enabled (include "polaris.secretsSplit" .)) -}}
{{- fail "backend.responseWorker is enabled but backend.secrets.responseKeys is empty: the Response Worker would hold no Response Plugin credential and could contain nothing. List the plugin credentials there." -}}
{{- end -}}
{{- toYaml (uniq $keys) -}}
{{- end -}}

{{/*
Refuses a Response Worker configuration that would leave containment with nowhere to run:
its credentials set up (its ExternalSecret) while the Response Worker itself is off.
*/}}
{{- define "polaris.responseWorkerGuard" -}}
{{- $rw := .Values.backend.responseWorker -}}
{{- if and (not $rw.enabled) $rw.externalSecret.enabled -}}
{{- fail "backend.responseWorker.externalSecret is enabled but backend.responseWorker.enabled is false: the Response Plugin credentials would sit in a Secret no workload runs with, and confirmed compromises would not be contained. Enable the Response Worker, or turn its ExternalSecret off and leave the credentials in backend.secrets.responseKeys for the default worker." -}}
{{- end -}}
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
{{- .Values.geoip.existingSecret | default (include "polaris.workloadSecretName" (dict "root" . "workload" "worker")) -}}
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

{{/*
Device access (Polaris ADR-0155): the BunkerWeb settings that make ingress.hosts answer
only enrolled devices from outside the internal network.

- optional: every handshake completes, so the two decisions below can be made per request.
- MTLS_URL_1: every path except the exempt ones needs a verified certificate. Only in
  mode enforce: before that, certificates are requested and forwarded but nobody is
  refused, so the backend's report shows who would be.
- WHITELIST_IP: the internal network skips that check. A whitelist match stops BunkerWeb's
  access phase before the mTLS plugin runs, so every other whitelist source is emptied:
  the defaults (search-engine rDNS, an ASN) would otherwise bypass mTLS.
*/}}
{{- define "polaris.deviceAccess.annotations" -}}
{{- $da := .Values.deviceAccess -}}
bunkerweb.io/USE_MTLS: "yes"
bunkerweb.io/MTLS_VERIFY_CLIENT: "optional"
bunkerweb.io/MTLS_CA_CERTIFICATE_PRIORITY: "data"
bunkerweb.io/MTLS_CA_CERTIFICATE_DATA: {{ required "deviceAccess.caBundle must be set when deviceAccess.enabled" $da.caBundle | quote }}
bunkerweb.io/MTLS_VERIFY_DEPTH: "2"
bunkerweb.io/MTLS_FORWARD_CLIENT_HEADERS: "yes"
{{- if eq $da.mode "enforce" }}
bunkerweb.io/MTLS_URL_1: {{ printf "^/(?!(?:%s))" $da.exemptPathsRegex | quote }}
{{- end }}
bunkerweb.io/USE_WHITELIST: "yes"
bunkerweb.io/WHITELIST_IP: {{ include "polaris.deviceAccess.internalCidrs" . | replace "," " " | quote }}
{{- range list "WHITELIST_IP_URLS" "WHITELIST_RDNS" "WHITELIST_RDNS_URLS" "WHITELIST_ASN" "WHITELIST_ASN_URLS" "WHITELIST_USER_AGENT" "WHITELIST_USER_AGENT_URLS" "WHITELIST_URI" "WHITELIST_URI_URLS" "WHITELIST_HEADER_NAME" "WHITELIST_HEADER_VALUE" }}
bunkerweb.io/{{ . }}: ""
{{- end }}
{{- end -}}

{{/* The internal network, comma-separated. Enabling device access without one would
let nobody enrol, so it is required. */}}
{{- define "polaris.deviceAccess.internalCidrs" -}}
{{- $cidrs := .Values.deviceAccess.internalCidrs | default list -}}
{{- if not $cidrs -}}
{{- fail "deviceAccess.internalCidrs must list the internal network when deviceAccess.enabled — devices can only enrol from it" -}}
{{- end -}}
{{- join "," $cidrs -}}
{{- end -}}

{{/* The public hosts as a YAML list, empty unless device access is on. */}}
{{- define "polaris.deviceAccess.publicHosts" -}}
{{- if .Values.deviceAccess.enabled -}}
{{- toYaml (.Values.deviceAccess.publicHosts | default list) -}}
{{- else -}}
[]
{{- end -}}
{{- end -}}

{{/* The Secret holding the Device CA intermediate, its key and the chain above it. */}}
{{- define "polaris.deviceAccess.signerSecretName" -}}
{{- $signer := .Values.deviceAccess.signer -}}
{{- if $signer.existingSecret -}}
{{- $signer.existingSecret -}}
{{- else if $signer.vault.enabled -}}
polaris-device-ca
{{- else -}}
{{- fail "deviceAccess.signer.existingSecret (or signer.vault.enabled) must be set when deviceAccess.enabled — the backend signs Device Certificates with it" -}}
{{- end -}}
{{- end -}}

{{/* The web pod's view of the signer Secret. Only the web pod signs, so only it mounts the key. */}}
{{- define "polaris.deviceAccess.appEnv" -}}
{{- if .Values.deviceAccess.enabled -}}
{{- $dir := .Values.deviceAccess.signer.mountPath -}}
- name: DEVICE_CA_CERT_PATH
  value: {{ printf "%s/ca.pem" $dir | quote }}
- name: DEVICE_CA_KEY_PATH
  value: {{ printf "%s/ca.key" $dir | quote }}
- name: DEVICE_CA_CHAIN_PATH
  value: {{ printf "%s/chain.pem" $dir | quote }}
{{- end -}}
{{- end -}}

{{- define "polaris.deviceAccess.appVolumeMount" -}}
{{- if .Values.deviceAccess.enabled -}}
- name: device-ca
  mountPath: {{ .Values.deviceAccess.signer.mountPath }}
  readOnly: true
{{- end -}}
{{- end -}}

{{- define "polaris.deviceAccess.volume" -}}
{{- if .Values.deviceAccess.enabled -}}
- name: device-ca
  secret:
    secretName: {{ include "polaris.deviceAccess.signerSecretName" . }}
    defaultMode: 0400
{{- end -}}
{{- end -}}
