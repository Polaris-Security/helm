"""Each backend workload gets its own Secret with only the keys it uses (helm#3, Polaris
PRD #1213, ADR-0159).

Legacy mode, the default, renders exactly what the chart rendered before (the goldens in
tests/golden were rendered from the chart before the split existed). Split mode mounts one
Secret per workload, holding the keys listed for it, and never a Response Plugin
credential on web.

Run: python -m pytest tests/  (needs helm, PyYAML and pytest)
"""
from pathlib import Path

import pytest
import yaml

from test_device_access import CHART, find, render, render_fails

GOLDEN = Path(__file__).resolve().parent / "golden"
CI = CHART / "ci"

SPLIT = [
    "--set", "backend.secrets.mode=split",
    "--set", "backend.secrets.web.keys={SECRET_KEY,REDIS_URL,AUTHENTIK_ENROLLMENT_API_TOKEN}",
    "--set", "backend.secrets.worker.keys={SECRET_KEY,REDIS_URL,AUTHENTIK_READER_API_TOKEN}",
    "--set", "backend.secrets.responseKeys={AUTHENTIK_RESPONSE_API_TOKEN,ENTRA_CLIENT_SECRET}",
]
WITH_ESO = [
    "--set", "externalSecrets.secretStore.enabled=true",
    "--set", "backend.secrets.externalSecret.enabled=true",
    "--set", "backend.secrets.externalSecret.remoteKey=kv/polaris/backend",
]


def secret_refs(docs):
    """``{(deployment, container): [Secret names it mounts with envFrom]}``."""
    out = {}
    for d in docs:
        if d["kind"] != "Deployment":
            continue
        spec = d["spec"]["template"]["spec"]
        for c in spec.get("initContainers", []) + spec["containers"]:
            refs = [e["secretRef"]["name"] for e in c.get("envFrom", []) if "secretRef" in e]
            if refs:
                out[(d["metadata"]["name"], c["name"])] = refs
    return out


def keys_of(docs, name):
    return [entry["secretKey"] for entry in find(docs, "ExternalSecret", name)["spec"]["data"]]


# ── Legacy ────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("case", ["default", "minimal", "full", "geoip", "device-access"])
def test_legacy_mode_renders_exactly_what_it_did_before(case):
    """Compared as parsed manifests, so a Helm version that formats YAML differently does
    not fail it; any change to what this chart deploys does. The goldens were rendered from
    the chart before the split (a8bc259), with the image tags pinned to `golden`."""
    args = [] if case == "default" else ["-f", str(CI / f"{case}-values.yaml")]
    before = [d for d in yaml.safe_load_all((GOLDEN / f"legacy-{case}.yaml").read_text()) if d]
    assert own(render(*args, *PINNED)) == own(before)


# The image tags move with every Polaris release (the "update image tags" commits), so the
# goldens and this render both pin them.
PINNED = ["--set", "backend.image.tag=golden", "--set", "frontend.image.tag=golden"]


def own(docs):
    """What this chart's own templates render: the subcharts (Valkey, Asset Discovery) carry
    a `helm.sh/chart` label and change with their own versions, so they are left out."""
    return [d for d in docs
            if "helm.sh/chart" not in ((d.get("metadata") or {}).get("labels") or {})]


def test_legacy_mode_mounts_the_one_secret_everywhere():
    refs = secret_refs(render())
    assert refs and all(names == ["backend-secret"] for names in refs.values())


# ── Split ─────────────────────────────────────────────────────────────────────


def test_split_mode_mounts_each_workloads_own_secret():
    assert secret_refs(render(*SPLIT)) == {
        ("backend", "migrate"): ["backend-migrate"],
        ("backend", "backend"): ["backend-web"],
        ("celery-worker", "celery-worker"): ["backend-worker"],
        ("celery-beat", "celery-beat"): ["backend-beat"],
    }


def test_each_workloads_external_secret_holds_exactly_its_keys():
    docs = render(*SPLIT, *WITH_ESO)
    assert keys_of(docs, "backend-web") == ["SECRET_KEY", "REDIS_URL",
                                            "AUTHENTIK_ENROLLMENT_API_TOKEN"]
    # No Response Worker yet: the default worker takes the Response Plugin credentials.
    assert keys_of(docs, "backend-worker") == ["SECRET_KEY", "REDIS_URL",
                                               "AUTHENTIK_READER_API_TOKEN",
                                               "AUTHENTIK_RESPONSE_API_TOKEN",
                                               "ENTRA_CLIENT_SECRET"]
    remote = find(docs, "ExternalSecret", "backend-web")["spec"]["data"][0]["remoteRef"]
    assert remote == {"key": "kv/polaris/backend", "property": "SECRET_KEY"}


def test_beat_and_migrate_render_with_the_minimal_key_sets():
    docs = render(*SPLIT, *WITH_ESO)
    assert keys_of(docs, "backend-beat") == ["SECRET_KEY", "REDIS_URL"]
    assert keys_of(docs, "backend-migrate") == ["SECRET_KEY"]


def test_bring_your_own_secrets_renders_no_external_secret():
    docs = render(*SPLIT)
    assert not [d for d in docs if d["kind"] == "ExternalSecret"
                and d["metadata"]["name"].startswith("backend-")]


def test_the_exporter_and_geoip_read_the_workers_secret():
    docs = render(*SPLIT, "--set", "geoip.enabled=true")
    exporter = find(docs, "Deployment", "celery-exporter")
    env = {e["name"]: e for e in exporter["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["CE_BROKER_URL"]["valueFrom"]["secretKeyRef"]["name"] == "backend-worker"
    worker = find(docs, "Deployment", "celery-worker")["spec"]["template"]["spec"]
    geoip_refs = {e["valueFrom"]["secretKeyRef"]["name"]
                  for c in worker["initContainers"] for e in c.get("env", [])
                  if "secretKeyRef" in e.get("valueFrom", {})}
    assert geoip_refs == {"backend-worker"}


def test_a_secret_can_be_renamed():
    refs = secret_refs(render(*SPLIT, "--set", "backend.secrets.web.name=polaris-web"))
    assert refs[("backend", "backend")] == ["polaris-web"]


# ── Mistakes fail the render ──────────────────────────────────────────────────


@pytest.mark.parametrize("key", ["ENTRA_CLIENT_SECRET", "AUTHENTIK_API_TOKEN",
                                 "AUTHENTIK_RESPONSE_API_TOKEN", "MAILU_DOVEADM_API_KEY"])
def test_web_listing_a_response_plugin_credential_fails(key):
    failed, err = render_fails(*SPLIT, "--set",
                               f"backend.secrets.web.keys={{SECRET_KEY,REDIS_URL,{key}}}")
    assert failed and f"lists {key}, a Response Plugin credential" in err


def test_web_listing_one_of_the_operators_response_keys_fails():
    failed, err = render_fails(*SPLIT, "--set", "backend.secrets.responseKeys={CUSTOM_IDP_KEY}",
                               "--set", "backend.secrets.web.keys={SECRET_KEY,REDIS_URL,CUSTOM_IDP_KEY}")
    assert failed and "CUSTOM_IDP_KEY" in err


@pytest.mark.parametrize("workload,keys,missing", [
    ("migrate", "{REDIS_URL}", "SECRET_KEY"),
    ("beat", "{SECRET_KEY}", "REDIS_URL"),
    ("web", "{REDIS_URL}", "SECRET_KEY"),
])
def test_a_workload_missing_a_core_key_fails(workload, keys, missing):
    failed, err = render_fails(*SPLIT, "--set", f"backend.secrets.{workload}.keys={keys}")
    assert failed and f"backend.secrets.{workload}.keys must include {missing}" in err


def test_an_unknown_mode_fails():
    failed, err = render_fails("--set", "backend.secrets.mode=separate")
    assert failed and "must be legacy or split" in err
