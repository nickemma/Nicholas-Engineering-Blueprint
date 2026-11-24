# 00 Before you start

You will deploy the jobs path from [Core 03](../../../../2-core/03-docker-and-postgres/README.md) and the metadata path from [Core 08](../../../../2-core/08-shipping-safely/README.md), which includes the Core 07 Raft implementation. Keep these codebases in separate subdirectories so both Go modules retain their own dependencies.

Use Linux, Go and Rust from the core, Docker Engine, kind, kubectl, Helm, Python 3, OpenSSL 3, Cosign, Syft, and promtool or Docker access for the Prometheus rules. The reference cluster used kind v0.33.0 and Kubernetes v1.37.0. Pair the kind release with one of its supported node images. [kind releases](https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0)

From the Blueprint checkout, run `export blueprint=$(pwd)`. In your own scratch directory, place fresh completed Core 03 and Core 08 code under `jobs/` and `core/`. The replay utility can reconstruct each source tree. Its `--keep` flag prints the directory it built.

<!-- continue: ../../../../2-core/03-docker-and-postgres into jobs -->
<!-- continue: ../../../../2-core/08-shipping-safely into core -->

Keep a kubeconfig for the lab separate from other contexts.

~~~bash
mkdir -p .lab
export KUBECONFIG="$PWD/.lab/kubeconfig"
kind create cluster --name blueprint-delivery --kubeconfig "$KUBECONFIG"
kubectl config current-context
kubectl get nodes
~~~

Use `kind-blueprint-delivery` for the examples. Cluster commands in later lessons are labeled **Run locally**. The offline replay covers Go tests, Helm rendering, and the release check without depending on a pre-existing cluster.
