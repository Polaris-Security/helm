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
Hostnames Django accepts requests for. Defaults to the Ingress hosts plus the in-cluster
Service DNS name, so a hostname is normally declared exactly once (ingress.hosts).
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
Pod-level settings shared by every workload: image pull secrets and the component's
scheduling directives. Each block is omitted when unset, and the whole include collapses
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
