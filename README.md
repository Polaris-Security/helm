# Polaris Security — Helm chart

Helm chart for deploying the **Polaris Security** platform on Kubernetes.

Documentation, product information and support: **https://polaris-security.nl/**

---

## What's in here

A single chart, `charts/polaris-platform`, that deploys the whole platform and the
supporting infrastructure it expects:

| Component | What it is |
| --- | --- |
| `backend` | Django/gunicorn web tier, with a `migrate` init container |
| `celery-worker` | Celery workers for background processing |
| `celery-beat` | Periodic task scheduler (single replica by design) |
| `frontend` | SPA served over HTTP |
| Ingress | One Ingress routing `/api/`, `/django-admin/`, `/static/`, `/auth/` and friends to the backend, everything else to the frontend |
| PostgreSQL | A CloudNativePG `Cluster` (optional), with S3/WAL archiving and scheduled backups via the barman-cloud plugin |
| Valkey | Celery broker and cache, via the Bitnami subchart (optional) |
| `ollama-embed` | Self-hosted Ollama used only for embeddings; chat models run on Ollama Cloud |
| Monitoring | ServiceMonitors, a celery-exporter, a Grafana dashboard ConfigMap and PrometheusRule alerts for an existing kube-prometheus-stack |
| external-secrets | Optional `SecretStore`/`ExternalSecret` for pulling backup credentials from Vault |

Every environment-specific setting lives in `values.yaml`; the templates carry no
site-specific values.

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
helm repo add polaris https://polaris-security.github.io/helm
helm repo update
helm upgrade --install polaris polaris/polaris -f my-values.yaml
```

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
| `externalSecrets` | Only if you pull secrets from a vault. |

`values.yaml` is commented throughout — read it as the reference for everything else.

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
   its subchart, attaches it to a GitHub Release, and updates the `index.yaml` served
   from the `gh-pages` branch.

The patch version is bumped automatically when the version in `Chart.yaml` has already
been released. For a minor or major release, edit `version:` in `Chart.yaml` yourself —
an unreleased version is used as-is. `appVersion` tracks the Polaris platform release
and is not touched by CI; bump it with the image tags.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
