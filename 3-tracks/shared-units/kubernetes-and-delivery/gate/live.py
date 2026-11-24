"""Exercise the Switchyard release in a fresh namespace on a local kind cluster."""

import argparse
import contextlib
import json
import os
import re
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


def call(*args, checked=True, timeout=120, **kwargs):
    return subprocess.run(args, check=checked, text=True, capture_output=True,
                          timeout=timeout, **kwargs)


def until(check, what, seconds=90):
    finish = time.monotonic() + seconds
    while time.monotonic() < finish:
        value = check()
        if value:
            return value
        time.sleep(0.6)
    raise AssertionError(f"timed out: {what}")


def http(base, path, data=None, context=None):
    headers = {"Content-Type": "application/json"} if data is not None else {}
    req = urllib.request.Request(base + path, data, headers)
    try:
        with urllib.request.urlopen(req, timeout=4, context=context) as response:
            return response.status, response.read(), response.headers
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(), exc.headers
    except (OSError, urllib.error.URLError):
        return 0, b"", {}


class Lab:
    def __init__(self, namespace, root, args):
        self.ns, self.root, self.args = namespace, root, args

    def kube(self, *args, **kwargs):
        return call("kubectl", "-n", self.ns, *args, **kwargs)

    def helm(self, *args):
        return call("helm", "upgrade", "--install", "delivery", "./chart", "-n", self.ns, *args)

    def json(self, *args):
        return json.loads(self.kube(*args, "-o", "json").stdout)

    @contextlib.contextmanager
    def forward(self, resource, target_port, tls=False):
        with tempfile.TemporaryFile(mode="w+b") as capture:
            process = subprocess.Popen(
                ["kubectl", "-n", self.ns, "port-forward", "--address=127.0.0.1",
                 resource, f":{target_port}"],
                stdout=capture, stderr=subprocess.STDOUT,
            )
            try:
                def address():
                    output = os.pread(capture.fileno(), 16384, 0)
                    if process.poll() is not None:
                        raise AssertionError(output.decode())
                    match = re.search(rb"Forwarding from 127\.0\.0\.1:(\d+)", output)
                    return match[1].decode() if match else None
                port = until(address, resource + " forwarding", 30)
                yield f"{'https' if tls else 'http'}://127.0.0.1:{port}"
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

    def image(self, deployment):
        return self.json("get", "deployment", deployment)["spec"]["template"]["spec"]["containers"][0]["image"]

    def apply_alert_probe(self, entry, prometheus, firing, seconds=85):
        stop = time.monotonic() + seconds
        while time.monotonic() < stop:
            assert http(entry, "/health")[0] == 200, "stable endpoint failed"
            code = http(entry, "/candidate/health")[0]
            if not firing and code != 200:
                time.sleep(0.7)
                continue
            status, raw, _ = http(prometheus, "/api/v1/alerts")
            if status == 200:
                active = [x["labels"]["track"] for x in json.loads(raw)["data"]["alerts"]
                          if x["state"] == "firing" and x["labels"]["alertname"] == "DeliveryBudgetBurn"]
                assert "stable" not in active, active
                if ("canary" in active) == firing:
                    return
            time.sleep(0.7)
        raise AssertionError(f"expected canary alert firing={firing}")

    def metadata(self, operation, key, value="", want=None):
        path = self.root / "secrets/gateway"
        role = "writer" if operation == "put" else "reader"
        ctx = ssl.create_default_context(cafile=str(path / "ca.crt"))
        ctx.load_cert_chain(path / (role + ".crt"), path / (role + ".key"))
        data = json.dumps({"Op": operation, "Key": key, "Value": value}).encode()
        for i in range(3):
            with self.forward(f"pod/metadata-{i}", 8443, tls=True) as url:
                code, raw, _ = http(url, "/command", data, ctx)
            if code == 200:
                out = json.loads(raw)
                if out["found"] and out["value"] == want:
                    return (i,)
        return None

    def network_boundary(self, entry):
        assert http(entry, "/health")[0] == 200
        values = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "policy-client"},
                  "spec": {"restartPolicy": "Never", "automountServiceAccountToken": False,
                           "securityContext": {"runAsNonRoot": True, "runAsUser": 65532,
                                               "seccompProfile": {"type": "RuntimeDefault"}},
                           "containers": [{"name": "check", "image": self.args.probe_image,
                                           "imagePullPolicy": "IfNotPresent",
                                           "securityContext": {"allowPrivilegeEscalation": False,
                                                               "capabilities": {"drop": ["ALL"]}},
                                           "command": ["sh", "-ec", (
                                               "curl -fsS --max-time 5 http://frontend-entry:8080/health >/dev/null; "
                                               "echo 'entry path allowed'; result=0; "
                                               "curl -fsS --max-time 4 http://jobs:8080/health >/dev/null || result=$?; "
                                               "test \"$result\" = 28; echo 'direct access timed out'"
                                           )]}]}}
        # Only submit the root-user fixture to server-side admission.
        values["spec"]["securityContext"]["runAsUser"] = 0
        denied = self.kube("apply", "--dry-run=server", "-f", "-", input=json.dumps(values), checked=False)
        assert denied.returncode != 0 and "violates PodSecurity" in denied.stderr, denied.stderr
        print("Pod Security: rejected a root-user fixture at admission", flush=True)
        values["spec"]["securityContext"]["runAsUser"] = 65532
        self.kube("apply", "-f", "-", input=json.dumps(values))
        self.kube("wait", "--for=jsonpath={.status.phase}=Succeeded", "pod/policy-client", "--timeout=45s")
        print(self.kube("logs", "policy-client").stdout.strip(), flush=True)

    def run(self):
        args = self.args
        call("bash", "ops/verify-release.sh", args.stable, args.public_key)
        result = call("bash", "ops/verify-release.sh", args.unsigned, args.public_key, checked=False)
        assert result.returncode != 0, "unsigned artifact passed verification"
        print("release: verified signature and SPDX attestation; unsigned digest refused", flush=True)

        self.kube("label", "namespace", self.ns, "pod-security.kubernetes.io/enforce=restricted")
        call("bash", "ops/lab-secrets.sh", self.ns, self.root / "secrets")
        self.helm("--set", f"image={args.stable},metadata.enabled=true,observability.enabled=true,"
                          "scaler.enabled=true,networkPolicy=true")
        self.kube("wait", "--for=condition=complete", "job/migrate", "--timeout=150s", timeout=165)
        for deployment in ("jobs", "worker", "frontend-entry", "frontend-stable", "frontend-canary",
                           "collector", "prometheus", "grafana", "worker-scaler"):
            self.kube("rollout", "status", f"deployment/{deployment}", "--timeout=90s")
        self.kube("rollout", "status", "statefulset/metadata", "--timeout=90s")
        stable = self.json("get", "pods", "-l", "app=frontend-stable")["items"]
        expected = args.stable.split("@")[1]
        assert len(stable) == 2 and all(
            pod["status"]["containerStatuses"][0]["imageID"].endswith(expected) for pod in stable
        ), "the running stable Pods did not report the verified manifest digest"
        print("identity: both stable Pods reported the verified manifest digest", flush=True)
        with self.forward("service/grafana", 3000) as grafana:
            until(lambda: http(grafana, "/api/dashboards/uid/switchyard-delivery")[0] == 200,
                  "provisioned Grafana dashboard", 20)
        print("Grafana: the provisioned delivery dashboard was readable", flush=True)
        with self.forward("service/frontend-entry", 8080) as entry, \
                self.forward("service/prometheus", 9090) as prometheus:
            def submit(duration):
                code, body, _ = http(entry, "/jobs", json.dumps(
                    {"description": "delivery fixture", "duration_ms": duration}).encode())
                assert code == 201, (code, body)
                return json.loads(body)["id"]

            def completed(job):
                code, body, _ = http(entry, f"/jobs/{job}")
                return code == 200 and json.loads(body)["state"] == "completed"

            job = submit(0)
            until(lambda: completed(job), "original job completion", 35)
            key, value = "delivery-fixture", "retained-after-replacement"
            leader = until(lambda: self.metadata("put", key, value, want=value), "metadata commit", 80)[0]
            print("baseline: jobs and metadata clients saw committed state", flush=True)

            self.kube("delete", "pod", "-l", "app=worker", "--wait=false")
            assert completed(job), "completed job disappeared at worker replacement"
            for _ in range(12):
                submit(5000)
            until(lambda: self.json("get", "deployment", "worker")["spec"]["replicas"] > 1,
                  "backlog to raise worker replicas", 25)
            identity = f"system:serviceaccount:{self.ns}:worker-scaler"
            allowed = self.kube("auth", "can-i", "update", "deployment/worker", "--subresource=scale", "--as="+identity)
            forbidden = self.kube("auth", "can-i", "update", "deployment/worker", "--as="+identity, checked=False)
            assert allowed.stdout.strip() == "yes" and forbidden.stdout.strip() == "no"
            print("controller: durable backlog drove scale-up; RBAC denied Deployment edits", flush=True)

            code, _, headers = http(entry, "/health")
            trace = headers.get("X-Lab-Trace")
            assert code == 200 and trace
            def collected():
                logs = self.kube("logs", "deployment/collector", checked=False).stdout
                spans = [part for part in logs.split("Span #") if trace in part]
                names = [re.search(r"Name\s*:\s*(frontend-[a-z]+)", part) for part in spans]
                if not {"frontend-entry", "frontend-stable"} <= {x.group(1) for x in names if x}:
                    return False
                ids = {}
                for part, name in zip(spans, names):
                    if name:
                        parent = re.search(r"Parent ID\s*:\s*([0-9a-f]*)", part)
                        span = re.search(r"(?m)^\s*ID\s*:\s*([0-9a-f]+)", part)
                        if parent and span:
                            ids[name.group(1)] = (parent.group(1), span.group(1))
                return len(ids) == 2 and ids["frontend-stable"][0] == ids["frontend-entry"][1]
            until(collected, "Collector parent and child spans", 35)
            print("tracing: Collector received the stable frontend span as a child of the entry span", flush=True)

            self.helm("--reuse-values", "--set", f"canaryImage={args.candidate},canaryFault=true")
            def candidate_failed():
                pods = self.json("get", "pods", "-l", "app=frontend-canary")["items"]
                for pod in pods:
                    detail = pod["spec"]["containers"][0]
                    if detail["image"] != args.candidate or "-fail-ready" not in detail["args"]:
                        continue
                    if any("running" in c["state"] and not c["ready"]
                           for c in pod.get("status", {}).get("containerStatuses", [])):
                        return True
                return False
            until(candidate_failed, "built candidate running but unready")
            result = call("bash", "ops/promote.sh", self.ns, args.candidate, args.public_key, checked=False)
            assert result.returncode != 0 and "timed out" in result.stderr.lower(), result.stderr
            assert self.image("frontend-stable") == args.stable and completed(job)
            print("canary: candidate was running and unready; promotion stopped and stable served the original job", flush=True)
            self.apply_alert_probe(entry, prometheus, True)
            print("alert: canary fired while stable stayed healthy", flush=True)
            self.helm("--reuse-values", "--set", f"canaryImage={args.stable},canaryFault=false")
            self.kube("rollout", "status", "deployment/frontend-canary", "--timeout=90s")
            self.apply_alert_probe(entry, prometheus, False)
            print("rollback: restored the known digest and cleared the canary alert", flush=True)

            peer = (leader + 1) % 3
            pod = f"metadata-{peer}"
            claim = f"wal-metadata-{peer}"
            claim_id = self.json("get", "pvc", claim)["metadata"]["uid"]
            pod_id = self.json("get", "pod", pod)["metadata"]["uid"]
            leader_logs = self.kube("logs", f"metadata-{leader}", "-c", "metad").stdout
            index = max(map(int, re.findall(r"applied peer=\d+ index=(\d+)", leader_logs)))
            self.kube("delete", "pod", pod, "--timeout=60s")
            until(lambda: (x := self.kube("get", "pod", pod, "-o", "json", checked=False)).returncode == 0
                  and json.loads(x.stdout)["metadata"]["uid"] != pod_id, "replacement voter")
            self.kube("wait", "--for=condition=Ready", "pod/"+pod, "--timeout=90s")
            def replayed():
                lines = self.kube("logs", pod, "-c", "metad", checked=False).stdout
                applied = list(map(int, re.findall(r"applied peer=\d+ index=(\d+)", lines)))
                return applied and max(applied) >= index
            until(replayed, "replacement voter applied the original prefix")
            assert self.json("get", "pvc", claim)["metadata"]["uid"] == claim_id
            assert until(lambda: self.metadata("get", key, want=value), "original metadata value")
            print("durability: replacement voter reused its claim and applied the committed prefix", flush=True)
            self.network_boundary(entry)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stable", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--unsigned", required=True)
    parser.add_argument("--public-key", type=Path, required=True)
    parser.add_argument("--probe-image", default="curlimages/curl:8.18.0")
    args = parser.parse_args()
    assert len({args.stable, args.candidate, args.unsigned}) == 3, "provide three distinct digests"
    context = call("kubectl", "config", "current-context").stdout.strip()
    assert context.startswith("kind-"), "select a disposable kind context"
    with tempfile.TemporaryDirectory(prefix="delivery-") as tmp:
        root = Path(tmp)
        namespace = ("delivery-" + root.name.split("-", 1)[1]).lower().replace("_", "-")
        lab = Lab(namespace, root, args)
        lab.kube("create", "namespace", namespace)
        try:
            lab.run()
        except Exception:
            print(lab.kube("get", "pods,pvc,deploy,job", checked=False).stdout)
            raise
        finally:
            lab.kube("delete", "namespace", namespace, "--wait=false", checked=False)


if __name__ == "__main__":
    main()
