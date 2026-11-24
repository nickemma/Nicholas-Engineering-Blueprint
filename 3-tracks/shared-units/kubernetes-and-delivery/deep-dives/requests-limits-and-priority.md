# Observe CPU throttling, memory kills and Pod preemption

Use the [disposable kind cluster](workloads-and-rollouts.md) with cgroup v2. A request is a scheduling input. A limit constrains the container at runtime. CPU time can be divided into smaller shares. A memory allocation needs space when it happens. See those effects in different Pods before comparing them to scheduling and node pressure.

## 1. Run two resource-limited Pods

The CPU Pod keeps consuming CPU and writes its output to `/dev/null`. The memory Pod writes to a memory-backed volume until it exceeds the container's memory limit. The shell check reads the CPU cgroup counter and the Kubernetes termination reason.

Create `resources.yaml`.

<!-- file: resources.yaml -->
~~~~yaml
apiVersion: v1
kind: Pod
metadata:
  name: cpu
spec:
  restartPolicy: Never
  containers:
    - name: worker
      image: busybox:1.37
      command: [dd, if=/dev/zero, of=/dev/null, bs=65536]
      resources:
        requests:
          cpu: 20m
          memory: 8Mi
        limits:
          cpu: 50m
          memory: 32Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: memory
spec:
  restartPolicy: Never
  containers:
    - name: worker
      image: busybox:1.37
      command: [dd, if=/dev/zero, of=/scratch/blob, bs=1M, count=64]
      resources:
        requests:
          cpu: 20m
          memory: 8Mi
        limits:
          cpu: 100m
          memory: 32Mi
      volumeMounts:
        - name: scratch
          mountPath: /scratch
  volumes:
    - name: scratch
      emptyDir:
        medium: Memory
        sizeLimit: 128Mi
~~~~

## 2. Make scheduling fail for a reason you can name

Advertise exactly one artificial slot on the lab node. Schedule a low-priority Pod holding the slot. A high-priority Pod requesting the same slot forces the scheduler to preempt the first. The slot lets you test preemption without reserving most of the host's real memory.

Create `priority.yaml`.

<!-- file: priority.yaml -->
~~~~yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: blueprint-low
value: 100
globalDefault: false
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: blueprint-high
value: 1000
globalDefault: false
~~~~

Create `slot-pod.yaml`.

<!-- file: slot-pod.yaml -->
~~~~yaml
apiVersion: v1
kind: Pod
metadata:
  name: POD_NAME
spec:
  priorityClassName: PRIORITY_CLASS
  restartPolicy: Never
  containers:
    - name: worker
      image: busybox:1.37
      command: [sleep, "600"]
      resources:
        limits:
          blueprint.example/slot: "1"
~~~~

Create `check-scheduling.sh`.

<!-- file: check-scheduling.sh -->
~~~~bash
#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?Point KUBECONFIG at the disposable kind cluster}"
test "$(kubectl config current-context)" = kind-blueprint-platform-build
namespace="scheduling-lab-${RANDOM}-$$"
node="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
kubectl create namespace "$namespace"
cleanup() {
  kubectl delete namespace "$namespace" --wait=false >/dev/null
  kubectl delete -f priority.yaml --ignore-not-found >/dev/null
  kubectl patch node "$node" --subresource status --type=json \
    -p '[{"op":"remove","path":"/status/capacity/blueprint.example~1slot"}]' >/dev/null 2>&1 || true
}
trap cleanup EXIT
k() { kubectl -n "$namespace" "$@"; }

k apply -f resources.yaml
k wait --for=condition=Ready pod/cpu --timeout=60s
for _ in {1..20}; do
  count="$(k exec cpu -- awk '$1 == "nr_throttled" {print $2}' /sys/fs/cgroup/cpu.stat)"
  if [[ "$count" =~ ^[0-9]+$ ]] && ((count > 0)); then
    break
  fi
  sleep 1
done
test "$count" -gt 0
echo "CPU pod stayed ready and recorded $count throttled periods"
k wait --for=jsonpath='{.status.containerStatuses[0].state.terminated.reason}'=OOMKilled \
  pod/memory --timeout=60s
echo "memory pod terminated with OOMKilled"
k delete -f resources.yaml >/dev/null

kubectl apply -f priority.yaml
kubectl patch node "$node" --subresource status --type=merge \
  -p '{"status":{"capacity":{"blueprint.example/slot":"1"}}}'
kubectl wait --for=jsonpath='{.status.allocatable.blueprint\.example/slot}'=1 \
  node/"$node" --timeout=60s
slot() { sed -e "s/POD_NAME/$1/" -e "s/PRIORITY_CLASS/$2/" slot-pod.yaml | k apply -f -; }
slot low blueprint-low
k wait --for=condition=Ready pod/low --timeout=60s
slot high blueprint-high
k wait --for=condition=Ready pod/high --timeout=90s
k get events --field-selector reason=Preempted
test -n "$(k get events --field-selector reason=Preempted,involvedObject.name=low -o name)"
echo "scheduler preempted low so high could claim the one advertised slot"
~~~~

<!-- run: bash -n check-scheduling.sh -->
~~~~bash
bash -n check-scheduling.sh
~~~~

~~~~bash
bash check-scheduling.sh
~~~~

The run recorded 16 throttled periods while the CPU Pod remained ready. The memory Pod terminated with `OOMKilled`. The scheduler recorded a `Preempted` event for the low-priority Pod and the high-priority Pod became ready.

Kubelet node-pressure eviction is a fourth case. Inspect `kubectl describe node` for `MemoryPressure`, `DiskPressure` and PID pressure. For an evicted Pod, inspect its reason and node events. Contrast that evidence with the container-local `OOMKilled` and the scheduler's `Preempted` event. [Node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/) · [Pod priority and preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)

## 3. Decide which autoscaler can help

If a Deployment falls behind and nodes have room, increase replicas. Follow the [custom-metric HPA build](../../../ai-infrastructure/02-serving-and-scaling-models/lessons/06-deploy-a-slow-starting-dependency.md) to run a Prometheus adapter and drive horizontal scale with actual backlog.

To measure vertical sizing, install only the VPA recommender and the resource metrics pipeline on the disposable kind cluster. The TLS override is for this lab's kubelets. Inspect the `metrics.k8s.io` APIService to see how API aggregation sends metrics requests to a separate service. [Kubernetes resource metrics pipeline](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/) · [VPA project](https://github.com/kubernetes/autoscaler/tree/vertical-pod-autoscaler-1.3.0/vertical-pod-autoscaler)

~~~~bash
vpa=https://raw.githubusercontent.com/kubernetes/autoscaler/vertical-pod-autoscaler-1.3.0/vertical-pod-autoscaler/deploy
kubectl apply -f "$vpa/vpa-v1-crd-gen.yaml" -f "$vpa/vpa-rbac.yaml" -f "$vpa/recommender-deployment.yaml"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deploy/metrics-server --timeout=120s
kubectl -n kube-system rollout status deploy/vpa-recommender --timeout=120s
kubectl get apiservice v1beta1.metrics.k8s.io
~~~~

Use `workloads.yaml` from the [workload build](workloads-and-rollouts.md). Create `vpa.yaml`.

<!-- file: vpa.yaml -->
~~~~yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: api
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  updatePolicy:
    updateMode: "Off"
  resourcePolicy:
    containerPolicies:
      - containerName: http
        minAllowed:
          cpu: 10m
          memory: 8Mi
        maxAllowed:
          cpu: 200m
          memory: 128Mi
~~~~

~~~~bash
kubectl create namespace vpa-lab
kubectl -n vpa-lab apply -f workloads.yaml -f vpa.yaml
kubectl -n vpa-lab rollout status deploy/api --timeout=60s
kubectl -n vpa-lab wait --for=condition=RecommendationProvided vpa/api --timeout=240s
kubectl -n vpa-lab get vpa/api \
  -o jsonpath='{.status.recommendation.containerRecommendations[0].target}{"\n"}'
kubectl -n vpa-lab get deploy/api \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}{"\n"}'
kubectl delete namespace vpa-lab
~~~~

The recommender returned `{"cpu":"25m","memory":"128Mi"}`. The Deployment kept its original `20m` CPU request because the policy is recommend-only. Treat the result as a sample and check the bound before adopting it.

A Pod whose request cannot fit any node needs a smaller request or a node group with suitable capacity. A node autoscaler works within the group's size bounds. Follow the [EKS plan](development-and-provisioning.md) to see where those bounds come from. [Kubernetes workload autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/)
