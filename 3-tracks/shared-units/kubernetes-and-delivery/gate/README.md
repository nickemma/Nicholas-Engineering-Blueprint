# Gate · Kubernetes and delivery

Work from the finished lesson scratch directory. The offline check runs Go tests, renders the full Helm chart, and exercises the promotion logic against an unready candidate. An intentionally altered promoter must trip the same assertion.

~~~bash
bash "$blueprint/3-tracks/shared-units/kubernetes-and-delivery/gate/run.sh" "$PWD"
~~~

With promtool on your PATH, the offline gate also checks the rule fixtures. You can use the Prometheus image instead by setting `SWITCHYARD_DELIVERY_PROMTOOL=1` when running the command.

## Prepare the disposable kind lab

Use the kubeconfig created in [Before you start](../lessons/00-before-you-start.md). Run `kubectl config current-context` and confirm the context names your dedicated kind cluster. The reference used kind v0.33.0, whose network implements the policies exercised here.

The lab needs access to the image registry for PostgreSQL, the Collector, Prometheus, Grafana, and curl. If those images are cached locally, you may load them into the cluster instead. A Docker archive with only one platform should be imported as that platform. The chart pins the fixture versions in `chart/values.yaml`.

Create a local registry and lab signing key. Choose a free host port. The private key and generated client keys belong in your scratch directory.

~~~bash
mkdir -p .lab/signing
bash ops/registry.sh blueprint-delivery 15119
cosign generate-key-pair --output-key-prefix .lab/signing/lab
bash ops/stage-db.sh
bash ops/ci-release.sh switchyard-delivery:release localhost:15119/delivery:stable \
  .lab/signing/lab.key .lab/signing/lab.pub .lab/stable.ref
~~~

Create two fixture image configurations with distinct manifests. The readiness fault is added at deploy time. Sign the candidate and leave the unsigned control without a signature.

~~~bash
for variant in candidate unsigned; do
  printf 'FROM switchyard-delivery:release\nLABEL io.switchyard.lab.fixture=%s\n' "$variant" |
    docker build --provenance=false -t "switchyard-delivery:$variant" -
  bash ops/publish.sh "switchyard-delivery:$variant" "localhost:15119/delivery:$variant" \
    > ".lab/$variant.ref"
done
bash ops/sign.sh "$(cat .lab/candidate.ref)" .lab/signing/lab.key
~~~

## Run the live gate

~~~bash
python3 "$blueprint/3-tracks/shared-units/kubernetes-and-delivery/gate/live.py" \
  --stable "$(cat .lab/stable.ref)" \
  --candidate "$(cat .lab/candidate.ref)" \
  --unsigned "$(cat .lab/unsigned.ref)" \
  --public-key .lab/signing/lab.pub
~~~

The gate creates and cleans up its own namespace. It checks actual client requests, Pod state, Prometheus alerts, Collectors, persisted data, and network policy. If direct access fails to time out, inspect whether the lab's networking implements NetworkPolicy. The test requires both the successful entry request and the denied direct request.

| Check | Passing result |
|---|---|
| Release identity | The trusted signature and SPDX attestation verify. An unsigned digest is refused. The running stable Pods report the verified manifest digest. |
| Canary and recovery | The candidate starts and stays unready, stable still returns the completed job, and restoring the known-good digest clears the canary alert. |
| Observability | The Collector receives parent and child spans for one client call, and the provisioned Grafana dashboard is readable. |
| Durable metadata | A replacement voter uses the same PVC UID, applies the committed prefix, and clients read the original value. |
| Controller and workload boundary | Backlog raises worker replicas. Restricted Pod Security rejects a root-user test at admission. The service account can change only the worker scale subresource. The lab Pod reaches the entry Service and times out on a direct jobs request. |

[Reference cluster transcript](../evidence/cluster-gate.txt)
