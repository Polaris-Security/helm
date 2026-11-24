"""Edge Devices (Polaris #1339) on the Asset Discovery chart: the device list the agent
reads (EDGE_DEVICES_FILE) and each device's credentials, mounted from its own Secret at
the paths the list names.

Run: python -m pytest tests/  (needs helm, PyYAML and pytest)
"""
import json
import subprocess
from pathlib import Path

import yaml

CHART = Path(__file__).resolve().parent.parent / "charts" / "polaris-asset-discovery"
PLATFORM = Path(__file__).resolve().parent.parent / "charts" / "polaris-platform"
CI_VALUES = CHART / "ci" / "edge-devices-values.yaml"


def helm(chart, *args):
    return subprocess.run(
        ["helm", "template", "d", str(chart), "--namespace", "polaris", *args],
        capture_output=True, text=True,
    )


def render(chart=CHART, *args):
    out = helm(chart, *args)
    assert out.returncode == 0, out.stderr
    return [d for d in yaml.safe_load_all(out.stdout) if d]


def of_kind(docs, kind):
    return [d for d in docs if d["kind"] == kind]


def agent(docs):
    (deploy,) = [d for d in of_kind(docs, "Deployment") if "asset-discovery" in d["metadata"]["name"]]
    return deploy["spec"]["template"]["spec"]


def device_list(docs):
    (cm,) = [d for d in of_kind(docs, "ConfigMap") if d["metadata"]["name"].endswith("-edge-devices")]
    return json.loads(cm["data"]["edge-devices.json"])


def test_no_devices_renders_nothing_extra():
    docs = render(CHART, "--set", "polaris.url=http://x")
    spec = agent(docs)
    env = {e["name"] for e in spec["containers"][0]["env"]}
    assert "EDGE_DEVICES_FILE" not in env
    assert not [d for d in of_kind(docs, "ConfigMap")]
    assert [v["name"] for v in spec["volumes"]] == ["tmp", "polaris-token"]


def test_device_list_points_at_mounted_secrets():
    docs = render(CHART, "-f", str(CI_VALUES))
    devices = {d["id"]: d for d in device_list(docs)}
    spec = agent(docs)
    container = spec["containers"][0]
    mounts = {m["name"]: m["mountPath"] for m in container["volumeMounts"]}
    volumes = {v["name"]: v for v in spec["volumes"]}

    env = {e["name"]: e.get("value") for e in container["env"]}
    assert env["EDGE_DEVICES_FILE"] == mounts["edge-devices"] + "/edge-devices.json"

    ns1 = devices["netscaler01"]
    assert ns1["kind"] == "netscaler" and ns1["verify_tls"] is False
    assert ns1["username_file"] == mounts["edge-device-0"] + "/username"
    assert ns1["password_file"] == mounts["edge-device-0"] + "/password"
    assert volumes["edge-device-0"]["secret"]["secretName"] == "netscaler01-reader"

    # kind is case-insensitive, keys are renamable, a caSecret becomes the CA path.
    ns2 = devices["netscaler02"]
    assert ns2["kind"] == "netscaler" and ns2["name"] == "NetScaler DC2"
    assert ns2["verify_tls"] == mounts["edge-device-1-ca"] + "/ca.pem"
    items = {i["path"]: i["key"] for i in volumes["edge-device-1"]["secret"]["items"]}
    assert items == {"username": "user", "password": "password"}
    assert volumes["edge-device-1-ca"]["secret"]["secretName"] == "edge-devices-ca"

    bw = devices["bunkerweb-dmz"]
    assert bw["token_file"] == mounts["edge-device-2"] + "/token"
    assert bw["verify_tls"] is True
    assert volumes["edge-device-2"]["secret"]["items"] == [{"key": "token", "path": "token"}]


def test_changing_the_list_rolls_the_pod():
    docs_a = render(CHART, "-f", str(CI_VALUES))
    docs_b = render(CHART, "-f", str(CI_VALUES), "--set", "edgeDevices[0].url=https://10.0.0.9")
    ann = lambda docs: of_kind(docs, "Deployment")[0]["spec"]["template"]["metadata"]["annotations"]
    assert ann(docs_a)["checksum/edge-devices"] != ann(docs_b)["checksum/edge-devices"]


def test_refuses_what_the_agent_would_refuse():
    base = ["--set", "polaris.url=http://x"]
    dev = "edgeDevices[0].id=a,edgeDevices[0].url=u,edgeDevices[0].existingSecret=s"
    bad_kind = helm(CHART, *base, "--set", dev + ",edgeDevices[0].kind=f5")
    assert bad_kind.returncode != 0 and "netscaler or bunkerweb" in bad_kind.stderr
    twice = helm(CHART, *base, "--set", dev + ",edgeDevices[0].kind=netscaler,"
                 "edgeDevices[1].id=a,edgeDevices[1].kind=netscaler,edgeDevices[1].url=u,"
                 "edgeDevices[1].existingSecret=s")
    assert twice.returncode != 0 and "listed twice" in twice.stderr
    no_secret = helm(CHART, *base, "--set", "edgeDevices[0].id=a,edgeDevices[0].kind=netscaler,"
                     "edgeDevices[0].url=u")
    assert no_secret.returncode != 0 and "existingSecret is required" in no_secret.stderr


def test_platform_passes_devices_to_the_in_cluster_agent():
    docs = render(PLATFORM, "--set", "assetDiscovery.edgeDevices[0].id=ns",
                  "--set", "assetDiscovery.edgeDevices[0].kind=netscaler",
                  "--set", "assetDiscovery.edgeDevices[0].url=https://10.0.0.5",
                  "--set", "assetDiscovery.edgeDevices[0].existingSecret=ns-reader")
    assert [d["id"] for d in device_list(docs)] == ["ns"]
