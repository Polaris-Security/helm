"""A `responseWorker` Deployment holds the Response Plugin credentials alone (helm#4,
Polaris PRD #1213, ADR-0159).

The Response Worker consumes only the `response` queue, with its own ServiceAccount,
Secret and ExternalSecret through a SecretStore of its own. Enabling it routes the
response tasks to it (RESPONSE_QUEUE_ENABLED on every backend pod) and takes the Response
Plugin credentials away from the default worker.

Run: python -m pytest tests/  (needs helm, PyYAML and pytest)
"""
import pytest

from test_backend_secrets import keys_of, secret_refs
from test_device_access import CHART, find, render, render_fails

CI = CHART / "ci" / "response-worker-values.yaml"
ON = ["-f", str(CI)]


def container(docs, deployment):
    return find(docs, "Deployment", deployment)["spec"]["template"]["spec"]["containers"][0]


def env(c):
    return {e["name"]: e.get("value") for e in c.get("env", [])}


# ── What renders ──────────────────────────────────────────────────────────────


def test_the_response_worker_consumes_only_the_response_queue():
    docs = render(*ON)
    c = container(docs, "celery-response-worker")
    assert c["command"][:4] == ["celery", "-A", "config", "worker"]
    assert c["command"][c["command"].index("-Q") + 1] == "response"
    # The default worker keeps the default queue.
    assert "-Q" not in container(docs, "celery-worker")["command"]


def test_it_has_its_own_service_account_and_mounts_no_token():
    docs = render(*ON)
    sa = find(docs, "ServiceAccount", "response-worker")
    assert sa["automountServiceAccountToken"] is False
    spec = find(docs, "Deployment", "celery-response-worker")["spec"]["template"]["spec"]
    assert spec["serviceAccountName"] == "response-worker"
    assert spec["automountServiceAccountToken"] is False
    assert spec["enableServiceLinks"] is False


def test_it_alone_holds_the_response_plugin_credentials():
    docs = render(*ON)
    refs = secret_refs(docs)
    assert refs[("celery-response-worker", "celery-response-worker")] == [
        "backend-response-worker"]
    assert keys_of(docs, "backend-response-worker") == [
        "SECRET_KEY", "REDIS_URL", "AUTHENTIK_RESPONSE_API_TOKEN", "ENTRA_TENANT_ID",
        "ENTRA_CLIENT_ID", "ENTRA_CLIENT_SECRET", "MAILU_API_TOKEN"]
    # The default worker no longer receives them.
    assert keys_of(docs, "backend-worker") == ["SECRET_KEY", "REDIS_URL",
                                               "AUTHENTIK_ENROLLMENT_API_TOKEN",
                                               "AUTHENTIK_READER_API_TOKEN"]
    assert "ENTRA_CLIENT_SECRET" not in keys_of(docs, "backend-web")


def test_its_secret_comes_through_a_store_that_signs_in_as_its_own_service_account():
    docs = render(*ON)
    store = find(docs, "SecretStore", "vault-response-worker")
    auth = store["spec"]["provider"]["vault"]["auth"]["kubernetes"]
    assert auth["role"] == "polaris-response-worker"
    assert auth["serviceAccountRef"] == {"name": "response-worker"}
    es = find(docs, "ExternalSecret", "backend-response-worker")
    assert es["spec"]["secretStoreRef"]["name"] == "vault-response-worker"
    assert {d["remoteRef"]["key"] for d in es["spec"]["data"]} == {"kv/polaris/response-worker"}
    # The backend workloads' store is not the Response Worker's.
    assert find(docs, "ExternalSecret", "backend-web")["spec"]["secretStoreRef"]["name"] \
        != "vault-response-worker"


def test_every_backend_pod_routes_response_tasks_to_it():
    docs = render(*ON)
    for name in ("backend", "celery-worker", "celery-beat", "celery-response-worker"):
        assert env(container(docs, name))["RESPONSE_QUEUE_ENABLED"] == "True", name


def test_without_it_nothing_routes_to_the_response_queue():
    docs = render()
    for name in ("backend", "celery-worker", "celery-beat"):
        assert "RESPONSE_QUEUE_ENABLED" not in env(container(docs, name))
    assert not [d for d in docs if d["metadata"]["name"] == "celery-response-worker"]


def test_the_security_context_is_locked_down():
    docs = render(*ON)
    c = container(docs, "celery-response-worker")
    assert c["securityContext"]["readOnlyRootFilesystem"] is True
    assert c["securityContext"]["allowPrivilegeEscalation"] is False
    assert c["securityContext"]["capabilities"]["drop"] == ["ALL"]
    assert c["volumeMounts"] == [{"name": "tmp", "mountPath": "/tmp"}]
    pod = find(docs, "Deployment", "celery-response-worker")["spec"]["template"]["spec"]
    assert pod["securityContext"]["runAsNonRoot"] is True


def test_the_network_policy_lets_nothing_in_and_only_what_it_needs_out():
    docs = render(*ON)
    policy = find(docs, "NetworkPolicy", "polaris-response-worker")["spec"]
    assert policy["podSelector"] == {"matchLabels": {"app": "celery-response-worker"}}
    assert policy["policyTypes"] == ["Ingress", "Egress"]
    assert "ingress" not in policy
    peers = [rule["to"][0] for rule in policy["egress"]]
    assert {"podSelector": {"matchLabels": {"cnpg.io/cluster": "cluster-polaris"}}} in peers
    assert {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "valkey"}}} in peers
    assert {"ipBlock": {"cidr": "203.0.113.10/32"}} in peers
    assert any(p.get("podSelector", {}).get("matchLabels", {}).get("k8s-app") == "kube-dns"
               for p in peers)


def test_web_mounts_no_token_unless_asset_discovery_needs_it():
    web = find(render(*ON), "Deployment", "backend")["spec"]["template"]["spec"]
    assert web["automountServiceAccountToken"] is False
    web = find(render(), "Deployment", "backend")["spec"]["template"]["spec"]
    assert "automountServiceAccountToken" not in web  # TokenReviews need it


def test_in_legacy_mode_it_can_bring_its_own_secret():
    docs = render("--set", "backend.responseWorker.enabled=true",
                  "--set", "backend.responseWorker.secret.name=polaris-response")
    assert secret_refs(docs)[("celery-response-worker", "celery-response-worker")] == [
        "polaris-response"]
    assert not [d for d in docs if d["kind"] == "ExternalSecret"
                and d["metadata"]["name"] == "polaris-response"]


# ── Mistakes fail the render ──────────────────────────────────────────────────


def test_its_credentials_configured_while_it_is_off_fails():
    failed, err = render_fails(*ON, "--set", "backend.responseWorker.enabled=false")
    assert failed and "confirmed compromises would not be contained" in err


def test_enabled_with_no_response_plugin_credential_fails():
    failed, err = render_fails(*ON, "--set", "backend.secrets.responseKeys=null")
    assert failed and "would hold no Response Plugin credential" in err


@pytest.mark.parametrize("missing", ["SECRET_KEY", "REDIS_URL"])
def test_its_secret_without_a_core_key_fails(missing):
    keep = "REDIS_URL" if missing == "SECRET_KEY" else "SECRET_KEY"
    failed, err = render_fails(*ON, "--set", f"backend.responseWorker.secret.keys={{{keep}}}",
                               "--set", "backend.secrets.responseKeys={ENTRA_CLIENT_SECRET}")
    assert failed and f"backend.responseWorker.secret.keys must include {missing}" in err
