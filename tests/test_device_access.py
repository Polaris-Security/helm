"""Device access (Polaris ADR-0155): outside the internal network, Polaris answers only
enrolled devices. BunkerWeb enforces it on the protected hosts from the Ingress
annotations this chart writes; the public pages live on a host of their own without
mTLS. These tests render the chart and read what BunkerWeb and the backend would get.

Run: python -m pytest tests/  (needs helm, PyYAML and pytest)
"""
import re
import subprocess
from pathlib import Path

import pytest
import yaml

CHART = Path(__file__).resolve().parent.parent / "charts" / "polaris-platform"

CA_BUNDLE = "-----BEGIN CERTIFICATE-----\nMIIBroot\n-----END CERTIFICATE-----\n"

ENABLED = [
    "--set", "deviceAccess.enabled=true",
    "--set", "deviceAccess.mode=enforce",
    "--set", "deviceAccess.internalCidrs={10.0.0.0/8,192.168.10.0/24}",
    "--set-string", f"deviceAccess.caBundle={CA_BUNDLE}",
    "--set", "deviceAccess.signer.existingSecret=polaris-device-ca",
    "--set", "deviceAccess.publicHosts={www.acme.test}",
    "--set", "ingress.hosts={polaris.acme.test,mobile.acme.test}",
]


def render(*args):
    out = subprocess.run(
        ["helm", "template", "polaris", str(CHART), "--namespace", "polaris", *args],
        check=True, capture_output=True, text=True,
    ).stdout
    return [d for d in yaml.safe_load_all(out) if d]


def render_fails(*args):
    result = subprocess.run(
        ["helm", "template", "polaris", str(CHART), "--namespace", "polaris", *args],
        capture_output=True, text=True,
    )
    return result.returncode != 0, result.stderr


def find(docs, kind, name):
    matches = [d for d in docs if d["kind"] == kind and d["metadata"]["name"] == name]
    assert matches, f"no {kind}/{name} in {[(d['kind'], d['metadata']['name']) for d in docs]}"
    return matches[0]


def hosts(ingress):
    return [rule["host"] for rule in ingress["spec"]["rules"]]


def bw(ingress):
    """The BunkerWeb settings an Ingress carries, unprefixed."""
    return {
        k.removeprefix("bunkerweb.io/"): v
        for k, v in (ingress["metadata"].get("annotations") or {}).items()
        if k.startswith("bunkerweb.io/")
    }


@pytest.fixture(scope="module")
def enabled():
    return render(*ENABLED)


# ── the protected hosts ───────────────────────────────────────────────────────


def test_the_protected_hosts_require_a_device_certificate_except_from_inside(enabled):
    ingress = find(enabled, "Ingress", "polaris")
    settings = bw(ingress)

    assert hosts(ingress) == ["polaris.acme.test", "mobile.acme.test"]
    assert settings["USE_MTLS"] == "yes"
    # optional: the handshake completes for everyone, so the per-path rule and the
    # internal whitelist can decide.
    assert settings["MTLS_VERIFY_CLIENT"] == "optional"
    assert settings["MTLS_CA_CERTIFICATE_PRIORITY"] == "data"
    assert settings["MTLS_CA_CERTIFICATE_DATA"].strip() == CA_BUNDLE.strip()
    assert settings["MTLS_FORWARD_CLIENT_HEADERS"] == "yes"
    assert settings["USE_WHITELIST"] == "yes"
    assert settings["WHITELIST_IP"] == "10.0.0.0/8 192.168.10.0/24"


def test_no_default_whitelist_source_can_bypass_the_certificate(enabled):
    """BunkerWeb's whitelist defaults let search-engine rDNS names and an ASN through, and
    a whitelisted client skips the mTLS check: on a protected host every source but the
    internal network must be empty."""
    settings = bw(find(enabled, "Ingress", "polaris"))

    for source in ("RDNS", "ASN", "USER_AGENT", "URI", "IP_URLS", "RDNS_URLS", "ASN_URLS",
                   "USER_AGENT_URLS", "URI_URLS", "HEADER_NAME", "HEADER_VALUE"):
        assert settings[f"WHITELIST_{source}"] == "", source


@pytest.mark.parametrize("path, protected", [
    ("/", True),
    ("/incidents/INC-2026-0042", True),
    ("/api/me/", True),
    ("/api/incidents/", True),
    ("/api/auth/mobile/redeem/", True),       # the code is useless without the device
    ("/api/me/devices/enrol/", True),
    ("/django-admin/", True),
    ("/api/authx/", True),
    ("/auth/openid/authentik/login/", False),  # the SSO browser leg, in Safari
    ("/api/auth/mobile/start/", False),
    ("/api/auth/mobile/complete/", False),
    ("/api/auth/mobile/callback/", False),
    ("/.well-known/apple-app-site-association", False),  # fetched by Apple's CDN
])
def test_every_path_needs_the_certificate_but_the_sso_leg(enabled, path, protected):
    pattern = bw(find(enabled, "Ingress", "polaris"))["MTLS_URL_1"]

    assert bool(re.search(pattern, path)) is protected


# ── the public host ───────────────────────────────────────────────────────────


def test_the_public_pages_live_on_their_own_host_without_mtls(enabled):
    """A visitor to the landing page is never asked for a certificate: the public host is
    a BunkerWeb service of its own, without USE_MTLS."""
    public = find(enabled, "Ingress", "polaris-public")

    assert hosts(public) == ["www.acme.test"]
    assert "USE_MTLS" not in bw(public)
    assert public["spec"]["tls"][0]["hosts"] == ["www.acme.test"]


def test_the_public_host_routes_only_endpoints_that_sign_no_person_in(enabled):
    public = find(enabled, "Ingress", "polaris-public")
    [rule] = public["spec"]["rules"]
    routes = {(p["path"], p["backend"]["service"]["name"]) for p in rule["http"]["paths"]}

    assert ("/api/ingest/", "backend") in routes
    assert ("/api/scim/", "backend") in routes
    assert ("/api/status/", "backend") in routes
    assert ("/", "frontend") in routes
    backend_paths = {path for path, service in routes if service == "backend"}
    assert not {"/api/", "/django-admin/", "/auth/"} & backend_paths


def test_a_public_host_is_never_also_a_protected_one(enabled):
    """The same server name on both Ingresses would make BunkerWeb merge them into one
    service, and the settings of one would apply to the other."""
    failed, message = render_fails(*ENABLED, "--set", "deviceAccess.publicHosts={polaris.acme.test}")

    assert failed
    assert "publicHosts" in message


# ── the backend ───────────────────────────────────────────────────────────────


def test_the_backend_agrees_with_bunkerweb_on_what_inside_means(enabled):
    config = find(enabled, "ConfigMap", "backend-config")["data"]

    assert config["INTERNAL_NETWORKS"] == "10.0.0.0/8,192.168.10.0/24"
    assert config["DEVICE_ACCESS_MODE"] == "enforce"


def test_the_backend_serves_the_public_host_too(enabled):
    config = find(enabled, "ConfigMap", "backend-config")["data"]

    assert "www.acme.test" in config["ALLOWED_HOSTS"].split(",")


def test_only_the_web_pod_holds_the_device_ca_key(enabled):
    web = find(enabled, "Deployment", "backend")["spec"]["template"]["spec"]
    [container] = [c for c in web["containers"] if c["name"] == "backend"]
    env = {e["name"]: e.get("value") for e in container["env"]}
    [volume] = [v for v in web["volumes"] if v["name"] == "device-ca"]
    [mount] = [m for m in container["volumeMounts"] if m["name"] == "device-ca"]

    assert volume["secret"]["secretName"] == "polaris-device-ca"
    assert mount["readOnly"] is True
    assert env["DEVICE_CA_CERT_PATH"] == f"{mount['mountPath']}/ca.pem"
    assert env["DEVICE_CA_KEY_PATH"] == f"{mount['mountPath']}/ca.key"
    assert env["DEVICE_CA_CHAIN_PATH"] == f"{mount['mountPath']}/chain.pem"
    for name in ("worker", "beat"):
        workload = [d for d in enabled if d["kind"] == "Deployment" and d["metadata"]["name"].endswith(name)]
        assert all("device-ca" not in str(d) for d in workload), name


# ── what the backend may trust ────────────────────────────────────────────────


def test_only_bunkerweb_and_the_release_reach_the_web_ports(enabled):
    """The backend trusts X-SSL-Client-* because only BunkerWeb can have set them."""
    for name, app in (("backend-web", "backend"), ("frontend", "frontend")):
        policy = find(enabled, "NetworkPolicy", f"polaris-{name}")
        assert policy["spec"]["podSelector"]["matchLabels"]["app"] == app
        [rule] = [r for r in policy["spec"]["ingress"] if any("namespaceSelector" in p for p in r.get("from", []))]
        namespaces = [p["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
                      for p in rule["from"] if "namespaceSelector" in p]
        assert namespaces == ["bunkerweb"]
        assert {"podSelector": {}} in rule["from"]


def test_the_device_ca_secret_can_come_from_vault():
    docs = render(*ENABLED, "--set", "deviceAccess.signer.existingSecret=",
                  "--set", "deviceAccess.signer.vault.enabled=true",
                  "--set", "externalSecrets.secretStore.enabled=true")
    secret = find(docs, "ExternalSecret", "polaris-device-ca")
    files = {d["secretKey"]: (d["remoteRef"]["key"], d["remoteRef"]["property"]) for d in secret["spec"]["data"]}

    assert files == {
        "ca.pem": ("kv/polaris-device-ca", "ca_pem"),
        "ca.key": ("kv/polaris-device-ca", "ca_key"),
        "chain.pem": ("kv/polaris-device-ca", "chain_pem"),
    }
    web = find(docs, "Deployment", "backend")["spec"]["template"]["spec"]
    [volume] = [v for v in web["volumes"] if v["name"] == "device-ca"]
    assert volume["secret"]["secretName"] == "polaris-device-ca"


@pytest.mark.parametrize("missing, flag, value", [
    ("internalCidrs", "--set", "deviceAccess.internalCidrs=null"),
    ("caBundle", "--set-string", "deviceAccess.caBundle="),
    ("existingSecret", "--set", "deviceAccess.signer.existingSecret="),
])
def test_enabling_device_access_without_what_it_needs_fails_the_render(missing, flag, value):
    failed, message = render_fails(*ENABLED, flag, value)

    assert failed
    assert missing in message


def test_with_device_access_off_nothing_changes():
    docs = render("--set", "deviceAccess.publicHosts={www.acme.test}")
    ingress = find(docs, "Ingress", "polaris")

    assert not bw(ingress)
    assert not [d for d in docs if d["kind"] in ("NetworkPolicy", "ExternalSecret")
                and d["metadata"]["name"] in ("polaris-backend-web", "polaris-frontend", "polaris-device-ca")]
    assert not [d for d in docs if d["kind"] == "Ingress" and d["metadata"]["name"] == "polaris-public"]
    config = find(docs, "ConfigMap", "backend-config")["data"]
    assert "INTERNAL_NETWORKS" not in config and "www.acme.test" not in config["ALLOWED_HOSTS"]
    assert "device-ca" not in str(find(docs, "Deployment", "backend"))


def test_in_report_mode_bunkerweb_forwards_certificates_but_refuses_nobody():
    """The rollout step: devices enrol and present their certificates, the backend logs
    who it would refuse, and nobody is locked out until mode is enforce."""
    settings = bw(find(render(*ENABLED, "--set", "deviceAccess.mode=report"), "Ingress", "polaris"))

    assert settings["USE_MTLS"] == "yes"
    assert settings["MTLS_VERIFY_CLIENT"] == "optional"
    assert settings["MTLS_FORWARD_CLIENT_HEADERS"] == "yes"
    assert "MTLS_URL_1" not in settings
