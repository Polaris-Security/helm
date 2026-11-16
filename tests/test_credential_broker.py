"""The Credential Broker fetches integration credentials from Vault on use (helm#5, Polaris
PRD #1214, ADR-0160).

With backend.credentials.backend=vault, web, the default worker and the Response Worker
each get a projected ServiceAccount token bound to Vault's audience with a short expiry,
their own Vault role, and their own Credential Manifest ConfigMap rendered from values;
no ExternalSecret copies an integration credential. With it off (the default) the chart
renders exactly what it did before (tests/golden/before-broker-*.yaml were rendered from
the chart before this change).

Run: python -m pytest tests/  (needs helm, PyYAML and pytest)
"""
import json
from pathlib import Path

import pytest
import yaml

from test_backend_secrets import PINNED, own
from test_device_access import CHART, find, render, render_fails

GOLDEN = Path(__file__).resolve().parent / "golden"
CI = CHART / "ci"
VAULT = ["-f", str(CI / "credential-broker-values.yaml")]

INTEGRATION_KEYS = {
    "ENTRA_TENANT_ID", "ENTRA_CLIENT_ID", "ENTRA_CLIENT_SECRET", "AUTHENTIK_API_TOKEN",
    "AUTHENTIK_ENROLLMENT_API_TOKEN", "AUTHENTIK_READER_API_TOKEN",
    "AUTHENTIK_RESPONSE_API_TOKEN", "NETBIRD_API_TOKEN", "MAILU_API_TOKEN",
    "MAILU_DOVEADM_API_KEY", "MAILU_SIEVE_PASSWORD", "BUNKERWEB_API_TOKEN",
    "SEMAPHORE_API_TOKEN", "GITHUB_TOKEN", "WAZUH_RULES_GITHUB_TOKEN",
}
BROKER_WORKLOADS = {"backend": "backend", "celery-worker": "celery-worker",
                    "celery-response-worker": "celery-response-worker"}


def pod(docs, deployment):
    return find(docs, "Deployment", deployment)["spec"]["template"]["spec"]


def app(docs, deployment):
    return next(c for c in pod(docs, deployment)["containers"] if c["name"] == deployment)


def env(c):
    return {e["name"]: e.get("value") for e in c.get("env", [])}


# ── Off: unchanged ────────────────────────────────────────────────────────────


@pytest.mark.parametrize("case", ["response-worker", "split-secrets"])
def test_off_renders_exactly_what_it_did_before(case):
    before = [d for d in yaml.safe_load_all((GOLDEN / f"before-broker-{case}.yaml").read_text())
              if d]
    assert own(render("-f", str(CI / f"{case}-values.yaml"), *PINNED)) == own(before)


def test_off_mounts_no_vault_token_and_sets_no_backend():
    docs = render("-f", str(CI / "response-worker-values.yaml"))
    for deployment in BROKER_WORKLOADS:
        spec = pod(docs, deployment)
        assert "vault-token" not in [v["name"] for v in spec.get("volumes", [])]
        assert "CREDENTIAL_BACKEND" not in env(app(docs, deployment))
    assert not [d for d in docs if d["metadata"]["name"].startswith("credential-manifest")]


# ── On ────────────────────────────────────────────────────────────────────────


def test_the_manifest_configmap_renders_from_values():
    docs = render(*VAULT)
    manifest = json.loads(find(docs, "ConfigMap", "credential-manifest-response-worker")
                          ["data"]["manifest.json"])
    assert manifest["entra"] == {
        "path": "polaris/response-worker/entra", "ttl": 30,
        "fields": {"tenant_id": "00000000-0000-0000-0000-000000000001",
                   "client_id": "00000000-0000-0000-0000-000000000002"}}
    assert set(manifest) == {"entra", "authentik.response"}
    web = json.loads(find(docs, "ConfigMap", "credential-manifest-web")["data"]["manifest.json"])
    assert set(web) == {"authentik.enrollment", "bunkerweb"}
    worker = json.loads(find(docs, "ConfigMap", "credential-manifest-worker")
                        ["data"]["manifest.json"])
    assert "authentik.response" not in worker


@pytest.mark.parametrize("deployment, manifest, role, account", [
    ("backend", "credential-manifest-web", "polaris-web", "backend"),
    ("celery-worker", "credential-manifest-worker", "polaris-worker", "celery-worker"),
    ("celery-response-worker", "credential-manifest-response-worker",
     "polaris-response-worker", "response-worker"),
])
def test_each_workload_signs_in_to_vault_with_a_short_lived_token_of_its_own(
        deployment, manifest, role, account):
    docs = render(*VAULT)
    spec = pod(docs, deployment)
    assert spec["serviceAccountName"] == account
    assert spec["automountServiceAccountToken"] is False
    volumes = {v["name"]: v for v in spec["volumes"]}
    token = volumes["vault-token"]["projected"]["sources"][0]["serviceAccountToken"]
    assert token == {"path": "token", "audience": "vault", "expirationSeconds": 600}
    assert volumes["credential-manifest"]["configMap"]["name"] == manifest

    c = app(docs, deployment)
    mounts = {m["name"]: m for m in c["volumeMounts"]}
    assert mounts["vault-token"]["mountPath"] == "/var/run/secrets/vault"
    assert mounts["vault-token"]["readOnly"] is True
    e = env(c)
    assert e["CREDENTIAL_BACKEND"] == "vault"
    assert e["VAULT_ADDR"] == "https://vault.acme.test:8200"
    assert e["VAULT_AUTH_ROLE"] == role
    assert e["VAULT_TOKEN_PATH"] == "/var/run/secrets/vault/token"
    assert e["CREDENTIAL_MANIFEST_PATH"] == "/etc/polaris/credentials/manifest.json"
    find(docs, "ServiceAccount", account)


def test_beat_and_migrate_get_no_vault_token():
    docs = render(*VAULT)
    beat = pod(docs, "celery-beat")
    assert "vault-token" not in [v["name"] for v in beat.get("volumes", [])]
    assert env(app(docs, "celery-beat"))["CREDENTIAL_BACKEND"] == "vault"
    assert "VAULT_AUTH_ROLE" not in env(app(docs, "celery-beat"))
    migrate = next(c for c in pod(docs, "backend")["initContainers"] if c["name"] == "migrate")
    assert "VAULT_AUTH_ROLE" not in env(migrate)
    assert not migrate.get("volumeMounts")


def test_no_external_secret_copies_an_integration_credential():
    docs = render(*VAULT)
    externals = [d for d in docs if d["kind"] == "ExternalSecret"]
    assert externals
    for es in externals:
        keys = {entry["secretKey"] for entry in es["spec"]["data"]}
        assert not keys & INTEGRATION_KEYS, es["metadata"]["name"]


def test_listed_response_keys_are_dropped_rather_than_copied():
    docs = render(*VAULT, "--set",
                  "backend.secrets.responseKeys={AUTHENTIK_RESPONSE_API_TOKEN,ENTRA_CLIENT_SECRET}")
    es = find(docs, "ExternalSecret", "backend-response-worker")
    assert {entry["secretKey"] for entry in es["spec"]["data"]} == {"SECRET_KEY", "REDIS_URL"}


def test_the_web_pod_still_mounts_no_api_token():
    spec = pod(render(*VAULT), "backend")
    assert spec["automountServiceAccountToken"] is False


def test_with_asset_discovery_web_keeps_its_token_review_account():
    docs = render(*VAULT, "--set", "assetDiscovery.enabled=true")
    assert pod(docs, "backend")["serviceAccountName"] == "backend"
    assert len([d for d in docs if d["kind"] == "ServiceAccount"
                and d["metadata"]["name"] == "backend"]) == 1


def test_vault_without_an_address_fails():
    failed, err = render_fails(*VAULT, "--set", "backend.credentials.vault.addr=")
    assert failed and "backend.credentials.vault.addr must be set" in err


def test_an_unknown_backend_fails():
    failed, err = render_fails("--set", "backend.credentials.backend=sops")
    assert failed and "must be env or vault" in err
