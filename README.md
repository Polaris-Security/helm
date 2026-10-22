# Polaris Security — Helm chart

Helm chart for deploying the **Polaris Security** platform on Kubernetes.

Chart repository: **https://helm.polaris-security.nl/**

Documentation, product information and support: **https://polaris-security.nl/**

---

## What's in here

The main chart, `charts/polaris-platform`, deploys the whole platform and the
supporting infrastructure it expects:

| Component | What it is |
| --- | --- |
| `backend` | Django/gunicorn web tier, with a `migrate` init container |
| `celery-worker` | Celery workers for background processing |
| `celery-beat` | Periodic task scheduler (single replica by design) |
| `frontend` | SPA served over HTTP |
| `mobile` | The mobile PWA, on its own hostname (optional — `mobile.enabled`) |
| Ingress | One Ingress routing `/api/`, `/django-admin/`, `/static/`, `/auth/` and friends to the backend, everything else to the frontend — and, when `mobile.enabled`, the same prefixes on `mobile.host`, its `apple-app-site-association` from the frontend, and the PWA as its catch-all |
| PostgreSQL | A CloudNativePG `Cluster` (optional), with S3/WAL archiving and scheduled backups via the barman-cloud plugin |
| Valkey | Celery broker and cache, via the Bitnami subchart (optional) |
| `ollama-embed` | Self-hosted Ollama used only for embeddings; chat models run on Ollama Cloud |
| Monitoring | ServiceMonitors, a celery-exporter, a Grafana dashboard ConfigMap and PrometheusRule alerts for an existing kube-prometheus-stack |
| external-secrets | Optional `SecretStore`/`ExternalSecret` for pulling backup credentials from Vault |
| Asset Discovery | The `polaris-asset-discovery` subchart (`assetDiscovery.enabled`, on by default): reports this cluster's workloads, their versions and their exposure to the platform as Workload Assets in the Infrastructure organisation. It authenticates with its Kubernetes service account token, which the backend checks with a TokenReview, so the backend web pod gets its own ServiceAccount bound to `system:auth-delegator` |

Every environment-specific setting lives in `values.yaml`; the templates carry no
site-specific values.

A second chart, `charts/polaris-asset-discovery`, runs Asset Discovery on its own for a cluster
the platform does not run in, using a Polaris Service Account token (see that chart's
`values.yaml`).

## Requirements

- Kubernetes >= 1.25 and Helm 3
- Pull credentials for the private `polarissecurity/*` images
- [CloudNativePG](https://cloudnative-pg.io/) operator — only if `postgres.enabled=true`
  (plus the barman-cloud plugin for `postgres.backup.enabled=true`)
- Prometheus Operator CRDs — only if `monitoring.enabled=true`
- [external-secrets.io](https://external-secrets.io/) — only if you use the
  `externalSecrets` section

Each of these is gated by a value, so the chart installs cleanly without them.

## Install

```sh
# Pull credentials for the private images
kubectl create secret docker-registry registry-credentials \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<user> --docker-password=<access-token>

# The backend environment. The chart deliberately does not create this Secret —
# bring it however you manage secrets (ExternalSecret, sealed-secrets, SOPS, ...).
# Must contain at least SECRET_KEY and REDIS_URL; POSTHOG_API_KEY if you use telemetry.
kubectl create secret generic backend-secret --from-env-file=.env

# Valkey password, read by the subchart. Must match the credentials inside REDIS_URL.
kubectl create secret generic valkey-secret --from-literal=valkey-password=<password>

# Add the chart repository and install
helm repo add polaris https://helm.polaris-security.nl/
helm repo update
helm upgrade --install polaris polaris/polaris -f my-values.yaml
```

Every release is also pushed to a ChartMuseum mirror at `https://charts.vels.online`.
Use it in place of the URL above when GitHub is unavailable.

`helm search repo polaris --versions` lists the available chart versions; pass
`--version` to pin one. To work from a checkout of this repository instead:

```sh
helm dependency build charts/polaris-platform
helm upgrade --install polaris charts/polaris-platform -f my-values.yaml
```

Before a first install, review at least:

| Value | Why |
| --- | --- |
| `ingress.hosts` | The public hostname(s) you serve on. Also the default source for `backend.allowedHosts` and `backend.csrfTrustedOrigins`, so you normally set a hostname exactly once. |
| `ingress.className` | Must match an IngressClass in your cluster. |
| `backend.existingSecret` | Name of the Secret holding the backend environment. |
| `imagePullSecrets` | Credentials for the private images. |
| `postgres` | Let CNPG provision a cluster, or point `postgres.urlSecret` at your own database. |
| `postgres.backup.destinationPath` | Ships as `s3://REPLACE-ME-cnpg-backups/`. |
| `postgres.recovery` | Off by default. Turn on only to restore a *new* cluster from the object store — see [Restoring from backup](#restoring-from-backup). |
| `externalSecrets` | Only if you pull secrets from a vault. |
| `mobile.enabled` / `mobile.host` | The mobile PWA and the hostname it answers on. Off by default; enabling it without a host fails the render. The host joins the derived `allowedHosts`/`csrfTrustedOrigins` and the Ingress `tls` block, so declare it only here. |
| `backend.config.DEPLOYMENT_BASE_URL` | The externally reachable origin of this install's API. Peering invites refuse to mint until it is set. |
| `FRONTEND_URL`, `DEFAULT_FROM_EMAIL`, `VAPID_SUBJECT` | The backend defaults all three to `vels.online` addresses. Unless you set them (in `backend.config`), outgoing email links to and is sent from the wrong site. |
| `backend.existingSecret` contents | Which keys the integrations you use need — see [Backend settings](#backend-settings). |

`values.yaml` is commented throughout — read it as the reference for every chart value.
The backend's own settings are listed under [Backend settings](#backend-settings).

### The mobile PWA

`mobile.enabled` adds a Deployment, a Service and a second Ingress rule on `mobile.host`.
That rule sends the same `ingress.backendPaths` to the backend as the main host does,
`/.well-known/apple-app-site-association` to the frontend, and everything else to the PWA
bundle. The association file comes from the frontend because that image is rebuilt every
release and the mobile image is not. The iOS app's Authentik sign-in depends on the file's
`webcredentials` entry being current on `mobile.host`.

`/auth/` matters as much as `/api/` here. The app signs people in over OIDC and exchanges
the resulting Django session for an API token, which only works while the whole round trip
stays on `mobile.host` — the session cookie has to be first-party to the app that reads
it. Two things outside the chart have to agree:

- the TLS certificate must cover `mobile.host` (the chart lists it under `tls`, but a
  cert-manager `Certificate` you manage yourself needs the SAN adding), and
- the identity provider must accept
  `https://<mobile.host>/auth/oidc/authentik/login/callback/` as a redirect URI.

## Backend settings

The backend is configured entirely through environment variables. Every backend pod
(web, the `migrate` init container, celery-worker, celery-beat) gets the same set, from
three places, later ones winning:

1. **`backend.existingSecret`** — every key, via `envFrom`. Credentials go here.
2. **`backend.config`, then `backend.extraConfig`** — rendered into the `backend-config`
   ConfigMap, also via `envFrom`. Non-secret settings go here. A key set here overrides
   the same key in the Secret.
3. **`backend.<web|worker|beat>.extraEnv`** — per tier, overriding both.

The chart derives some keys and writes them into the ConfigMap itself. Do not set these
yourself:

| Key | Derived from |
| --- | --- |
| `ALLOWED_HOSTS` | `backend.allowedHosts`, else `ingress.hosts` + `mobile.host` + the in-cluster Service name |
| `CSRF_TRUSTED_ORIGINS` | `backend.csrfTrustedOrigins`, else `https://` + each of those hosts |
| `POSTHOG_HOST` | `posthog.host` |
| `DATABASE_URL` | `postgres.urlSecret` (set directly on each container, not via the ConfigMap) |
| `ASSET_DISCOVERY_KUBERNETES_SERVICE_ACCOUNTS` | the Asset Discovery subchart's service account, when `assetDiscovery.enabled` |
| `ASSET_DISCOVERY_KUBERNETES_AUDIENCE` | `assetDiscovery.polaris.tokenAudience`, when `assetDiscovery.enabled` |
| `RELEASE`, `SERVICE_NAME` | the backend image tag and the tier, for telemetry |

Everything else is listed below. **S** marks a credential that belongs in the Secret;
the rest go in `backend.config`. Unset integrations stay off: the features that need
them report themselves unconfigured rather than failing.

### Core

| Variable | | Default | Purpose |
| --- | --- | --- | --- |
| `SECRET_KEY` | S | `12345` | Django signing key. **Always set it**; the default is not secret. Also seeds the fallback encryption keys below. |
| `REDIS_URL` | S | — | Valkey/Redis URL: Celery broker and cache. Required. The celery-exporter reads it too. |
| `DEBUG` | | `False` | Django debug mode. |
| `ENVIRONMENT` | | `development` | Telemetry environment tag. The chart sets `production`. |
| `LOG_LEVEL` | | `INFO` | Console log level. |
| `FRONTEND_URL` | | `https://vels.online` | Base URL of the web app, used for links in outgoing email. **Set it.** |
| `DEPLOYMENT_NAME` | | `Polaris Security` | This deployment's name, as peers see it. |
| `DEPLOYMENT_BASE_URL` | | — | Externally reachable origin of this API. Peering is unavailable until it is set. |
| `DISABLED_CAPABILITIES` | | — | Comma-separated capabilities this deployment lacks: `siem`, `vulnerability_management`, `edr`. |
| `LLM_CREDENTIAL_ENCRYPTION_KEY` | S | derived from `SECRET_KEY` | Fernet key for per-organisation LLM credentials. Set it so rotating `SECRET_KEY` does not invalidate them. |
| `OPERATIVE_SECRET_ENCRYPTION_KEY` | S | derived from `SECRET_KEY` | Fernet key for Operative Secrets. Same reasoning. |
| `CORS_ALLOWED_ORIGINS` | | — | Read but currently unused; no CORS middleware is installed. |

Generate a Fernet key with
`python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"`.

`DEV_AUTO_LOGIN` logs every visitor in as the admin superuser. It exists for local
docker-compose only — never set it on a deployed instance.

### Telemetry

| Variable | | Default | Purpose |
| --- | --- | --- | --- |
| `POSTHOG_API_KEY` | S | — | PostHog project token. Empty disables backend telemetry. |
| `POSTHOG_LOGS_ENABLED` | | `False` | Ship logs to PostHog Logs. |
| `POSTHOG_LOG_LEVEL` | | `WARNING` | Level shipped to PostHog Logs (the console keeps `LOG_LEVEL`). |

### Identity (Authentik)

| Variable | | Default | Purpose |
| --- | --- | --- | --- |
| `AUTHENTIK_SERVER_URL` | | — | OIDC issuer URL. Empty disables SSO login. |
| `AUTHENTIK_CLIENT_ID` | S | — | OIDC client ID. |
| `AUTHENTIK_CLIENT_SECRET` | S | — | OIDC client secret. |
| `AUTHENTIK_API_URL` | | — | Authentik API, used to invite and manage users. |
| `AUTHENTIK_API_TOKEN` | S | — | Token for that API. |
| `AUTHENTIK_ENROLLMENT_FLOW_SLUG` | | — | Enrollment flow invitations use. The chart sets `default-enrollment-flow`. |
| `TURNSTILE_SECRET_KEY` | S | — | Cloudflare Turnstile secret for the public sign-up form. The site key is baked into the frontend image at build time. |

### Email

| Variable | | Default | Purpose |
| --- | --- | --- | --- |
| `EMAIL_HOST` / `EMAIL_PORT` | | `localhost` / `587` | Outgoing SMTP relay. |
| `EMAIL_HOST_USER` | S | — | SMTP user. |
| `EMAIL_HOST_PASSWORD` | S | — | SMTP password. |
| `EMAIL_USE_TLS` / `EMAIL_USE_SSL` | | `True` / `False` | STARTTLS, or implicit TLS. |
| `EMAIL_SSL_NO_VERIFY` | | `False` | Skip certificate verification. The chart sets `True`; turn it off if your relay has a valid certificate. |
| `EMAIL_BACKEND` | | SMTP | Django email backend class, if you need a different one. |
| `DEFAULT_FROM_EMAIL` | | `noreply@vels.online` | Sender address. **Set it.** |
| `INBOUND_IMAP_HOST` / `INBOUND_IMAP_PORT` | | — / `993` | Mailbox polled for inbound alert mail and replies. |
| `INBOUND_IMAP_USER` | S | — | Its user. |
| `INBOUND_IMAP_PASSWORD` | S | — | Its password. |
| `INBOUND_IMAP_MAILBOX` | | `INBOX` | Folder to poll. |
| `INBOUND_REPLY_DOMAIN` | | the SOC mailbox's domain | Domain for contact reply handles. |
| `CONTACT_REPLY_HANDLE_EXPIRY_DAYS` | | `30` | How long a reply handle stays valid. |
| `PARTNER_INTAKE_VERIFY_AUTH` | | `1` | Require DKIM and SPF pass on partner intake mail. `0` turns the check off. |
| `PARTNER_INTAKE_RETENTION_DAYS` | | `30` | How long partner intake messages are kept. |

### Push notifications

| Variable | | Default | Purpose |
| --- | --- | --- | --- |
| `VAPID_PUBLIC_KEY` | | — | Web-push public key. |
| `VAPID_PRIVATE_KEY` | S | — | Web-push private key. Generate the pair once per deployment with `py_vapid`. |
| `VAPID_SUBJECT` | | `mailto:admin@vels.online` | Contact sent with web-push messages. **Set it.** |
| `APNS_AUTH_KEY` | S | — | PEM contents of the APNs `.p8` key. Empty turns iOS push off. |
| `APNS_KEY_ID` / `APNS_TEAM_ID` | | — | Identify that key. |
| `APNS_BUNDLE_ID` | | `nl.polarissecurity.Polaris` | The iOS app's bundle ID. |

### LLM providers

| Variable | | Default | Purpose |
| --- | --- | --- | --- |
| `OLLAMA_BASE_URL` | | `http://localhost:11434` | Ollama endpoint for chat and web search. |
| `OLLAMA_API_KEY` | S | — | Ollama Cloud key. Also enables assistant web search. |
| `OLLAMA_MODEL` | | `gpt-oss:20b` | Chat model. The chart sets `gpt-oss:120b-cloud`. |
| `OLLAMA_TIMEOUT_S` | | `60` | Per-call timeout. Keep it under gunicorn's timeout. |
| `GEMINI_API_KEY` | S | — | Gemini, the backup provider. |
| `GEMINI_MODEL` | | `gemini-3.8-flash` | Gemini chat model. |
| `EXCEPTION_`, `TRIAGE_`, `CORRELATION_`, `CLOSURE_`, `INCIDENT_ASSISTANT_`, `DISTILL_`, `HARVEST_LLM_PROVIDER` | | Ollama providers | Provider class per feature. The chart sets all but `HARVEST_`, which follows the triage provider. |
| `GROUNDING_WINDOW_DAYS` / `GROUNDING_VALUE_CAP` / `GROUNDING_SAMPLE_CAP` | | `30` / `50` / `15` | How much field-value history grounds triage. |
| `EMBED_MEASURE_PROVIDER` | | `ollama` | Embedding provider for the precedent-recall measurement job (`ollama` or `gemini`). |
| `OLLAMA_EMBED_MODEL` / `GEMINI_EMBED_MODEL` | | `nomic-embed-text` / `gemini-embedding-001` | Embedding models. Keep the Ollama one equal to `ollamaEmbed.model`. |
| `EMBED_TIMEOUT_S` / `EMBED_KEEP_ALIVE` | | `300` / `30m` | Embedding request timeout, and how long the model stays loaded. |

### Agent loop limits

Ceilings on how much work one run of each agent may do. Raise them when real runs keep
stopping at a cap; no release is needed.

| Variable | Default | Bounds |
| --- | --- | --- |
| `ASSISTANT_LOOP_MAX_ITERATIONS` / `ASSISTANT_LOOP_DEADLINE_S` | `10` / `150` | One Incident Assistant turn. |
| `ASSISTANT_TOOL_TIMEOUT_S` | `15` | One assistant tool call. |
| `ASSISTANT_MAX_AUTO_ACTIONS` / `ASSISTANT_MAX_PROPOSALS` | `8` / `3` | Actions taken, and confirm-cards shown, per turn. |
| `ASSISTANT_MAX_TOOL_RESULT_CHARS` / `ASSISTANT_GROUNDING_CHAR_BUDGET` | `20000` / `60000` | Context size of one tool result, and of the grounding block. |
| `ASSISTANT_MEMORY_TTL_S` / `ASSISTANT_MEMORY_CHAR_BUDGET` | `14400` / `240000` | Working Memory lifetime and size. |
| `ASSISTANT_CHAT_RETRIES` / `ASSISTANT_RETRY_BACKOFF_S` | `2` / `1.0` | Retries on a provider 5xx. |
| `ASSISTANT_WEB_SEARCH_ENABLED` | `1` | `0` turns assistant web search off. |
| `ASSISTANT_DEBUG_ENABLED` | `0` | `1` enables Incident Assistant debug mode for superusers. Leave off in production. |
| `HUNT_LOOP_MAX_ITERATIONS` / `HUNT_LOOP_DEADLINE_S` / `HUNT_TOOL_TIMEOUT_S` / `HUNT_MAX_AUTO_ACTIONS` | `15` / `300` / `15` / `8` | One threat-hunt turn. |
| `TRIAGE_AGENT_LOOP_MAX_ITERATIONS` / `TRIAGE_AGENT_LOOP_DEADLINE_S` | `15` / `300` | One Incident Agent work phase. |
| `TRIAGE_AGENT_MAX_MATERIALISED_EVENTS` | `10` | Events one Incident Agent run may turn into Alerts. |

### Operatives

Deployment-wide maximums: an Operative's own `limits` may ask for less, never more.

| Variable | Default | Bounds |
| --- | --- | --- |
| `OPERATIVE_MAX_ITERATIONS` / `OPERATIVE_MAX_DEADLINE_S` | `20` / `600` | One run. |
| `OPERATIVE_MAX_CONCURRENT_RUNS` / `OPERATIVE_MAX_RUNS_PER_ORG_PER_HOUR` | `4` / `60` | Throughput. |
| `OPERATIVE_TOOL_TIMEOUT_S` | `15` | One tool call. |
| `OPERATIVE_MODEL_TIMEOUT_S` / `OPERATIVE_MODEL_RETRIES` / `OPERATIVE_MODEL_RETRY_BACKOFF_S` | `300` / `3` / `5` | One model call, its retries and their initial backoff (doubling). |
| `OPERATIVE_API_TIMEOUT_S` / `OPERATIVE_API_MAX_RESPONSE_BYTES` / `OPERATIVE_API_MAX_RESPONSE_CHARS` | `10` / `262144` / `16000` | `fetch_api` / `call_api`. |
| `OPERATIVE_MEMORY_MAX_ENTRIES` / `OPERATIVE_MEMORY_MAX_CHARS` / `OPERATIVE_MEMORY_MAX_TTL_DAYS` | `50` / `20000` / `365` | Operative Memory per Operative and organisation. |
| `OPERATIVE_ARTIFACT_MAX_TEXT_BYTES` / `OPERATIVE_ARTIFACT_MAX_PDF_BYTES` / `OPERATIVE_ARTIFACT_MAX_WRITES_PER_RUN` | `1048576` / `20971520` / `10` | Artifact size and writes per run. |
| `OPERATIVE_ARTIFACT_INDEX_SHOWN` / `OPERATIVE_ARTIFACT_INDEX_MAX_CHARS` | `20` / `4000` | Artifacts listed to a run. |
| `OPERATIVE_EVENT_RETRY_DELAY_S` / `OPERATIVE_SCHEDULE_RETRY_DELAY_S` | `300` / `1800` | Delay before the one retry of a failed event run / a scheduled run that hit its deadline (`0` turns the latter off). |
| `OPERATIVE_RUN_LOG_RETENTION_DAYS` | `180` | How long runs and their logs are kept. |
| `OPERATIVE_ASSIGNMENT_MAX_RUNS` / `OPERATIVE_ASSIGNMENT_MAX_ROUNDS` | `20` / `3` | One team Assignment. |
| `OPERATIVE_DEBRIEF_TIMEOUT_S` / `OPERATIVE_CONSULTATION_DEADLINE_S` | `3600` / `300` | Waiting on Debriefs, and on a consulted Operative. |
| `OPERATIVE_ORPHAN_GRACE_S` | `600` | How long past its deadline a run may linger before it is ended as orphaned. |
| `OPERATIVE_DECISION_DEFAULT_HOURS` / `OPERATIVE_DECISION_MAX_HOURS` / `OPERATIVE_MAX_DECISIONS` | `24` / `72` / `5` | Decisions put to staff. |
| `OPERATIVE_STAFFING_MAX_DRAFTS_PER_RUN` / `_MAX_PROPOSALS_PER_RUN` / `_MAX_TRIAL_RUNS_PER_RUN` / `_MAX_DRAFT_REVISIONS` | `2` / `5` / `2` / `2` | One Staffing run. |

### Integrations

| Variable | | Default | Purpose |
| --- | --- | --- | --- |
| `WAZUH_API_URL` | | — | Wazuh manager API. |
| `WAZUH_API_USER` / `WAZUH_API_PASSWORD` | S | — | Its credentials. |
| `WAZUH_INDEXER_URL` | | — | Wazuh indexer (OpenSearch). |
| `WAZUH_INDEXER_USER` / `WAZUH_INDEXER_PASSWORD` | S | — | Its credentials. |
| `WAZUH_MANAGER_HOST` | | — | Manager address agents enrol against, shown in install instructions. |
| `WAZUH_REGISTRATION_PASSWORD` | S | — | Agent enrolment password, shown in install instructions. |
| `WAZUH_AGENT_VERSION` | | `4.12.0-1` | Agent version the install instructions pin. |
| `WAZUH_RULES_GITHUB_TOKEN` | S | — | GitHub token for publishing exception rules. |
| `SEMAPHORE_URL` / `SEMAPHORE_PROJECT_ID` | | — / `0` | Ansible Semaphore for remediation playbooks. The chart sets project `1`. |
| `SEMAPHORE_API_TOKEN` | S | — | Its token. |
| `SEMAPHORE_CONNECT_TIMEOUT` / `SEMAPHORE_READ_TIMEOUT` / `SEMAPHORE_LAUNCH_READ_TIMEOUT` | | `3` / `10` / `30` | Seconds. |
| `SEMAPHORE_CONNECT_ATTEMPTS` / `SEMAPHORE_RETRY_BACKOFF_S` | | `3` / `0.5` | Retries of connections that never reached Semaphore. |
| `BUNKERWEB_API_URL` | | — | BunkerWeb API for managing ingress services. |
| `BUNKERWEB_API_TOKEN` | S | — | Its token. |
| `BUNKERWEB_PUBLIC_IP` / `BUNKERWEB_PUBLIC_FQDN` | | — | The reverse proxy's public address and hostname. |
| `PULSEGRID_BASE_URL` / `PULSEGRID_ORG_ID` | | — | PulseGrid, behind the public status page. |
| `PULSEGRID_API_TOKEN` | S | — | Its read-only token. |
| `WASABI_ENDPOINT` / `WASABI_BUCKET` | | — | S3-compatible storage for file uploads and downloads. |
| `WASABI_ACCESS_KEY` / `WASABI_SECRET_KEY` | S | — | Its credentials. |
| `ABUSEIPDB_API_KEY`, `VIRUSTOTAL_API_KEY`, `URLSCAN_API_KEY`, `MSRC_API_KEY` | S | — | Enrichment and advisory lookups. Without `URLSCAN_API_KEY`, page captures can be searched but not commissioned. |
| `GITHUB_TOKEN` / `GITHUB_REPO` | S / | — | Where in-app feedback is filed as GitHub issues. |
| `KNOWLEDGE_EXCHANGE_REPO` / `KNOWLEDGE_EXCHANGE_BRANCH` | | — / `main` | The Knowledge Exchange commons. Empty repo disables the feature. |
| `KNOWLEDGE_EXCHANGE_OAUTH_CLIENT_ID` | | — | GitHub OAuth app for publishing to it. |
| `KNOWLEDGE_EXCHANGE_OAUTH_CLIENT_SECRET` | S | — | Its secret. |
| `KNOWLEDGE_EXCHANGE_PREMUTE_THRESHOLD` | | `100` | Volume at which an organisation is pre-selected for Mute on an imported rule. |

### Retention and housekeeping

| Variable | Default | Purpose |
| --- | --- | --- |
| `ONCALL_ROUTING` | `always` | `always` assigns every triaged incident to on-call; `llm_guided` only those triage says to escalate or assign. The chart sets `llm_guided`. |
| `ATTACK_MAP_SEVERITY_FLOOR` | `3` | Lowest severity shown on the attack map. |
| `ASSET_STALE_DAYS` | `90` | Days without a sighting before an agent asset is considered stale. |
| `DEPROVISIONING_RETENTION_DAYS` | `90` | How long a suspended organisation's data is kept before it is due for purge. |
| `PEERING_INVITE_EXPIRY_HOURS` / `PEERING_OFFER_RETENTION_DAYS` | `72` / `30` | Peering invite lifetime; how long unplaced share offers are kept. |
| `PEERING_INBOUND_RATE_LIMIT` / `PEERING_INBOUND_RATE_WINDOW_SECONDS` | `300` / `60` | Inbound request ceiling per peer; `0` disables it. |
| `WORK_PACKAGE_CRON_SCHEDULE` / `INCIDENT_DIGEST_CRON_SCHEDULE` | `0 6 * * 1` / `0 7 * * *` | **First install only.** Read by the migration that seeds the periodic tasks, so changing them later does nothing — edit the schedule in Django admin instead. |
| `EXCEPTION_CANDIDATE_MIN_EVIDENCE` / `_LOOKBACK_DAYS` / `_RECENCY_DAYS` | `3` / `90` / `30` | Exception Candidate thresholds. For test and staging installs only. |

### Frontend and mobile images

The frontend and mobile images are static bundles. Their settings — API base, PostHog
project and host, Turnstile site key — are baked in at build time, so `frontend.extraEnv`
and `mobile.extraEnv` cannot change them, and `posthog.host` applies to the backend only.

## Restoring from backup

`postgres.backup.enabled` only controls *archiving*. Restoring is a separate switch,
`postgres.recovery.enabled`, so a normal install can never be talked into wiping itself
by trying to restore.

CNPG reads `bootstrap` only when it **creates** a Cluster, so recovery cannot be applied
to a running one — you restore into a cluster that does not exist yet, either in a clean
namespace or after deleting the existing `Cluster` object.

```yaml
postgres:
  recovery:
    enabled: true
    # Empty ⇒ postgres.cluster.name. Set it if the backups were archived under
    # a different name than the cluster you are restoring into.
    sourceServerName: ""
```

Restoring in place — same cluster name, archiving back under the same name — is the
common case and works as-is. The restored cluster is promoted onto a new timeline, so its
WAL segments do not collide with the ones it replayed. Two caveats are worth knowing:

- **Retrying a restore.** A second attempt from the same base backup promotes onto the
  same timeline as the first, so it archives segments the first attempt already wrote.
  barman-cloud rejects the conflicting writes rather than overwriting them, which stalls
  WAL archiving and leaves segments accumulating on the PVC until it fills.
- **A mixed catalog.** Several cluster incarnations then live under one server name, so a
  later point-in-time recovery may need an explicit `backupID` to pin which one it means,
  and `retentionPolicy` ages all of them out together.

Set `postgres.backup.serverName` to give the restored cluster its own archive prefix and
sidestep both — at the cost of splitting the backup history in two:

```yaml
postgres:
  backup:
    serverName: cluster-polaris-restored
  recovery:
    enabled: true
```

Turn `recovery.enabled` back off once a restore has completed, so re-creating the Cluster
later doesn't silently restore again instead of starting fresh.

That replays every archived WAL segment, i.e. restores to the most recent transaction.
For point-in-time recovery, add a target — timestamps need an explicit timezone offset:

```yaml
postgres:
  recovery:
    enabled: true
    recoveryTarget:
      targetTime: "2026-08-19 14:30:00.000000+00"
```

CNPG picks the latest base backup preceding the target and replays WAL up to it. Other
targets: `targetLSN`, `targetXID`, `targetName` (a restore point created with
`pg_create_restore_point`), and `targetImmediate: true` to stop as soon as the restored
backup is consistent. `backupID` pins which base backup to start from, and
`exclusive: false` replays *through* the target rather than stopping just before it.

Recovery needs the barman-cloud plugin and the same S3 credentials as backups, and the
restored cluster comes up with the roles and databases the backup contained — the
`postgres.cluster.database`/`owner` values apply to `initdb` only.

## Notes

- **Resource names are stable literals** (`backend`, `frontend`, `backend-config`,
  `ollama-embed`) rather than release-prefixed: the backend reaches the embedder at
  `http://ollama-embed:11434` and the Ingress routes by name, so these are part of the
  in-cluster contract. **One release per namespace.**
- `backend.config` renders into the `backend-config` ConfigMap, which is listed *after*
  the backend Secret in `envFrom` — keys set there override the same keys in the Secret.
  Keep secrets out of it.
- `backend.beat.replicaCount` must stay at 1; more replicas double-schedule every
  periodic task.
- Chart `version` tracks changes to the chart itself; `appVersion` is the Polaris
  platform release the image tags default to.

## Development

```sh
helm dependency build charts/polaris-platform
helm lint charts/polaris-platform
helm template polaris charts/polaris-platform -f my-values.yaml
```

`charts/polaris-platform/ci/*-values.yaml` hold the configurations CI renders on every
push: `minimal-values.yaml` (every optional dependency disabled, external database) and
`full-values.yaml` (multi-host Ingress, external-secrets, per-component scheduling).
Add a case there when you add a value that changes what gets rendered.

## Releasing

Every push to `main` publishes the chart:

1. `.github/workflows/lint-test.yml` lints the chart, renders the default and CI values,
   validates the output against Kubernetes schemas with `kubeconform`, and asserts the
   required-value guards still fail loudly.
2. `.github/workflows/release.yml` then bumps the chart version, packages the chart with
   its subchart, attaches it to a GitHub Release, and updates the `index.yaml` on the
   `gh-pages` branch — served from GitHub Pages at https://helm.polaris-security.nl/.

The patch version is bumped automatically when the version in `Chart.yaml` has already
been released. For a minor or major release, edit `version:` in `Chart.yaml` yourself —
an unreleased version is used as-is. `appVersion` tracks the Polaris platform release
and is not touched by CI; bump it with the image tags.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
