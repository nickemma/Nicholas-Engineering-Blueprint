# Rotate a mounted Sealed Secret

Use the [disposable kind cluster](workloads-and-rollouts.md). Install the Sealed Secrets v0.30.0 controller and put the matching `kubeseal` binary on PATH. Use synthetic values for the check. The controller decrypts the declared SealedSecret and reconciles an ordinary Secret. The Pod consumes the ordinary Secret through a read-only volume. [Sealed Secrets project](https://github.com/bitnami-labs/sealed-secrets/tree/v0.30.0)

~~~~bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.30.0/controller.yaml
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=120s
~~~~

## Mount, rotate, and verify the scope

Keep the same running Pod through rotation and compare the file hash. A kubelet may take time to update a projected volume, so the check polls within a bound. Strict scope uses both the Secret's name and namespace. Copy the sealed value under a different name and verify that no Secret is produced. The Pod fits the namespace's restricted Pod Security policy.

Create `reader.yaml`.

<!-- file: reader.yaml -->
~~~~yaml
apiVersion: v1
kind: Pod
metadata:
  name: reader
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsUser: 10001
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: reader
      image: busybox:1.37
      command: [sleep, "420"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: credentials
          mountPath: /credentials
          readOnly: true
  volumes:
    - name: credentials
      secret:
        secretName: application
~~~~

Create `check-sealed.sh`.

<!-- file: check-sealed.sh -->
~~~~bash
#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?Point KUBECONFIG at the disposable kind cluster}"
test "$(kubectl config current-context)" = kind-blueprint-platform-build
namespace="secrets-lab-${RANDOM}-$$"
kubectl create namespace "$namespace"
trap 'kubectl delete namespace "$namespace" --wait=false >/dev/null' EXIT
k() { kubectl -n "$namespace" "$@"; }

seal() {
  k create secret generic application --from-literal="token=$1" --dry-run=client -o json |
    kubeseal --scope strict --format json > sealed.json
  k apply -f sealed.json
}

kubectl label namespace "$namespace" pod-security.kubernetes.io/enforce=restricted
seal demo-v1
k wait --for=condition=Synced sealedsecret/application --timeout=45s
k apply -f reader.yaml
k wait --for=condition=Ready pod/reader --timeout=45s
before="$(k exec reader -- sha256sum /credentials/token)"
seal demo-v2
expected="$(printf '%s' demo-v2 | sha256sum | awk '{print $1}')"
for _ in {1..90}; do
  after="$(k exec reader -- sha256sum /credentials/token)"
  if [[ "$after" == "$expected "* ]]; then
    break
  fi
  sleep 2
done
test "$before" != "$after"
test "${after%% *}" = "$expected"
echo "running Pod observed the rotated mounted Secret without logging its value"

python3 -c 'import json,sys; item=json.load(sys.stdin); item["metadata"]["name"]="wrong-name"; item["spec"]["template"]["metadata"]["name"]="wrong-name"; json.dump(item,sys.stdout)' \
  < sealed.json | k apply -f -
k wait --for=jsonpath='{.status.conditions[0].status}'=False \
  sealedsecret/wrong-name --timeout=45s
test -z "$(k get secret wrong-name --ignore-not-found -o name)"
echo "ciphertext sealed for application could not be unsealed under a different name"
~~~~

<!-- run: bash -n check-sealed.sh -->
~~~~bash
bash -n check-sealed.sh
~~~~

~~~~bash
bash check-sealed.sh
~~~~

~~~~text
running Pod observed the rotated mounted Secret without logging its value
ciphertext sealed for application could not be unsealed under a different name
~~~~

Repeat with a changed Pod that adds a forbidden capability and check the rejection before the container starts. Read [Enforce the deployment boundary](../lessons/10-enforce-the-deployment-boundary.md) to exercise workload RBAC and NetworkPolicy against the Switchyard stack.
