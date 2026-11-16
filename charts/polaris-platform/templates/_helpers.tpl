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
{{- toYaml (include "polaris.withoutIntegrationCredentials" (dict "root" .root "keys" (uniq $keys)) | fromYamlArray) -}}
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
{{- if include "polaris.credentialsVault" . }}
# Integration credentials come from Vault when used (Polaris ADR-0160); the backend then
# reads none of them from the environment. A pod without a Vault token (beat, migrate)
# simply has none.
- name: CREDENTIAL_BACKEND
  value: vault
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
{{- if and (not $response) (or $rw.externalSecret.enabled (include "polaris.secretsSplit" .)) (not (include "polaris.credentialsVault" .)) -}}
{{- fail "backend.responseWorker is enabled but backend.secrets.responseKeys is empty: the Response Worker would hold no Response Plugin credential and could contain nothing. List the plugin credentials there." -}}
{{- end -}}
{{- toYaml (include "polaris.withoutIntegrationCredentials" (dict "root" . "keys" (uniq $keys)) | fromYamlArray) -}}
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
{{- if .Values.assetDiscovery.enabled -}}backend
{{- else if include "polaris.credentialsVault" . -}}{{ .Values.backend.credentials.web.serviceAccount }}
{{- end -}}
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


{{/*
── The Credential Broker's Vault backend (Polaris PRD #1214, ADR-0160) ──────────────────

Whether integration credentials are fetched from Vault on use
(backend.credentials.backend=vault). Fails on anything but env or vault, and when vault
has no address.
*/}}
{{- define "polaris.credentialsVault" -}}
{{- $c := .Values.backend.credentials -}}
{{- $backend := $c.backend | default "env" -}}
{{- if eq $backend "vault" -}}
{{- $_ := required "backend.credentials.vault.addr must be set when backend.credentials.backend is vault" $c.vault.addr -}}true
{{- else if ne $backend "env" -}}
{{- fail (printf "backend.credentials.backend must be env or vault, not %q" $backend) -}}
{{- end -}}
{{- end -}}

{{/*
The env vars the backend's Credential Broker reads integration credentials from with its
env backend. With the Vault backend they are fetched on use, so no Secret holds them.
*/}}
{{- define "polaris.integrationCredentialKeys" -}}
- ENTRA_TENANT_ID
- ENTRA_CLIENT_ID
- ENTRA_CLIENT_SECRET
- AUTHENTIK_API_TOKEN
- AUTHENTIK_ENROLLMENT_API_TOKEN
- AUTHENTIK_READER_API_TOKEN
- AUTHENTIK_RESPONSE_API_TOKEN
- NETBIRD_API_TOKEN
- MAILU_API_TOKEN
- MAILU_DOVEADM_API_KEY
- MAILU_SIEVE_PASSWORD
- BUNKERWEB_API_TOKEN
- SEMAPHORE_API_TOKEN
- GITHUB_TOKEN
- WAZUH_RULES_GITHUB_TOKEN
{{- end -}}

{{/*
`keys` less the integration credentials when they come from Vault; `keys` otherwise.
Usage: include "polaris.withoutIntegrationCredentials" (dict "root" . "keys" $keys)
*/}}
{{- define "polaris.withoutIntegrationCredentials" -}}
{{- $keys := .keys -}}
{{- if include "polaris.credentialsVault" .root -}}
{{- $drop := include "polaris.integrationCredentialKeys" .root | fromYamlArray -}}
{{- $kept := list -}}
{{- range $keys -}}
{{- if not (has . $drop) -}}
{{- $kept = append $kept . -}}
{{- end -}}
{{- end -}}
{{- $keys = $kept -}}
{{- end -}}
{{- toYaml $keys -}}
{{- end -}}

{{/* Where the projected Vault token and the Credential Manifest are mounted. */}}
{{- define "polaris.vaultTokenDir" -}}/var/run/secrets/vault{{- end -}}
{{- define "polaris.credentialManifestDir" -}}/etc/polaris/credentials{{- end -}}

{{/*
The Credential Broker's env for a workload ("web", "worker", "responseWorker") with the
Vault backend; nothing otherwise.
Usage: include "polaris.credentialEnv" (dict "root" . "workload" "web")
*/}}
{{- define "polaris.credentialEnv" -}}
{{- if include "polaris.credentialsVault" .root -}}
{{- $c := .root.Values.backend.credentials -}}
{{- $w := index $c .workload -}}
- name: VAULT_ADDR
  value: {{ $c.vault.addr | quote }}
- name: VAULT_AUTH_MOUNT
  value: {{ $c.vault.authMount | quote }}
- name: VAULT_AUTH_ROLE
  value: {{ required (printf "backend.credentials.%s.role must be set" .workload) $w.role | quote }}
- name: VAULT_KV_MOUNT
  value: {{ $c.vault.kvMount | quote }}
{{- with $c.vault.namespace }}
- name: VAULT_NAMESPACE
  value: {{ . | quote }}
{{- end }}
- name: VAULT_TOKEN_PATH
  value: {{ printf "%s/token" (include "polaris.vaultTokenDir" .root) | quote }}
- name: CREDENTIAL_MANIFEST_PATH
  value: {{ printf "%s/manifest.json" (include "polaris.credentialManifestDir" .root) | quote }}
- name: CREDENTIAL_TTL_SECONDS
  value: {{ $c.vault.ttlSeconds | quote }}
- name: CREDENTIAL_FETCH_ALERT_MINUTES
  value: {{ $c.vault.fetchAlertMinutes | quote }}
{{- end -}}
{{- end -}}

{{/* The workload's mounts of its Vault token and its manifest, with the Vault backend. */}}
{{- define "polaris.credentialVolumeMounts" -}}
{{- if include "polaris.credentialsVault" .root -}}
- name: vault-token
  mountPath: {{ include "polaris.vaultTokenDir" .root }}
  readOnly: true
- name: credential-manifest
  mountPath: {{ include "polaris.credentialManifestDir" .root }}
  readOnly: true
{{- end -}}
{{- end -}}

{{/*
The volumes behind those mounts: a projected ServiceAccount token bound to Vault's
audience with a short expiry (the kubelet rotates it), and the workload's manifest.
*/}}
{{- define "polaris.credentialVolumes" -}}
{{- if include "polaris.credentialsVault" .root -}}
{{- $v := .root.Values.backend.credentials.vault -}}
- name: vault-token
  projected:
    sources:
      - serviceAccountToken:
          path: token
          audience: {{ $v.audience | quote }}
          expirationSeconds: {{ $v.tokenExpirationSeconds }}
- name: credential-manifest
  configMap:
    name: {{ include "polaris.credentialManifestName" . }}
{{- end -}}
{{- end -}}

{{- define "polaris.credentialManifestName" -}}
{{- printf "credential-manifest-%s" (.workload | kebabcase) -}}
{{- end -}}
