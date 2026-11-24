# Exercise · Ship a second service

Package a small service of your choice with a durable dependency. Use a separate namespace, stable deployment, and explicitly addressed canary. Decide which client operation proves the storage state and which client result should stop promotion.

## Acceptance checks

1. Build the image once, record the manifest digest, and sign both the image and an attached inventory. Verify the chosen digest before applying it.
2. Make the candidate start while failing readiness. Show that its explicit route fails and that the stable route still returns your seeded record. Capture the withheld promotion and independent alert if you instrument one.
3. Restore the last known good digest and verify both routes. Replace the stateful process and check that the stored record survives and that its claim UID is unchanged.
4. Configure a service account with the least permissions needed for its job. Use the Kubernetes authorization API to check one allowed and one denied operation.
5. Apply a narrow ingress policy and show one allowed request and one denied request from ordinary lab Pods. Include your test commands and observations in the handoff.

## Kubernetes platform extensions

Start with the [Kubernetes workload build](deep-dives/workloads-and-rollouts.md) in a disposable cluster, then pick a drill that matches the kind of platform work you expect to do.

### Cluster and workload fundamentals

On kind, follow a YAML Deployment from the API server to its ReplicaSet and Pods. Identify the scheduler, kubelet, worker nodes and the namespace boundary. Change replica count imperatively, then reconcile it from the declared manifest. Identify which labels and selectors assign traffic and which annotations carry metadata. Use rollout history, events, and current and previous logs to explain a failed health check. Compare the Deployment with a DaemonSet on eligible nodes and a finite batch Job. [Cluster architecture](https://kubernetes.io/docs/concepts/architecture/)

Trace traffic from a second Pod through DNS, a Service and its endpoints to the selected Pod. Compare ClusterIP, NodePort, LoadBalancer, and a headless Service. Exercise HTTP routing through an Ingress resource with a matching controller. Confirm the selected backend after its readiness changes.

### Development and cluster provisioning

Follow [Tilt and remote cluster provisioning](deep-dives/development-and-provisioning.md) before adapting the plan to your own environment.

Use Tilt to rebuild one service after a source edit and verify that the change reaches the local cluster. Use a clearly named kubeconfig context for an authorized remote sandbox and check the namespace and permissions before applying. With Terraform or OpenTofu, plan a sandbox cluster for one approved provider. If an account and budget are available, provision it, verify access and one workload, then tear it down and check for leftover network and storage resources. Portability practice is to identify each provider-specific cluster, identity and storage dependency in the plan.

### Access, configuration and secrets

Follow [the Sealed Secret build](deep-dives/rotate-a-sealed-secret.md) to check the rotation in a running Pod.

Mount configuration and a Secret separately. Use a namespace-scoped Sealed Secret for a disposable credential, rotate the credential, and prove that the workload picks up the new value. Check access through RBAC and test both permitted and denied routes with NetworkPolicy. Exercise Pod Security Standards through Pod Security Admission and capture one workload rejection and the smallest manifest change that permits it.

### Scheduling and autoscaling

Follow [the resource and priority build](deep-dives/requests-limits-and-priority.md) to reproduce throttling, an OOM kill and scheduler preemption.

Vary CPU and memory requests and limits. CPU time is compressible because competing tasks can receive less CPU time. Memory is incompressible in the sense that some allocations need capacity immediately. Compare CPU throttling with a memory-limit kill, kubelet node-pressure eviction, and scheduler preemption through PriorityClasses. Capture Pod and node conditions so you can distinguish all four outcomes. Compare horizontal autoscaling (replicas), vertical autoscaling (workload resources), and cluster autoscaling (nodes). Drive an HPA with queue backlog or another custom metric, then verify scale-up, scale-down, and a pending-Pod case where adding replicas alone cannot help. [Autoscaling workloads](https://kubernetes.io/docs/concepts/workloads/autoscaling/) · [Node autoscaling](https://kubernetes.io/docs/concepts/cluster-administration/node-autoscaling/) · [Node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/) · [Pod priority and preemption](https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/)

### API extensions and operators

Follow [the Report operator build](deep-dives/report-operator.md) for the scaffolding, reconciler and cleanup check.

Compare CRDs, admission webhooks, and API aggregation by identifying where each handles a request. Study reconciliation in cert-manager or policy admission in Kyverno. Use Kubebuilder to write a small operator whose CRD owns a batch Job. Reconcile the same object twice and verify there is one Job. Record a useful status condition and event. Use owner references for dependents and a finalizer for a simulated external allocation. Test deletion while cleanup fails, then let it succeed and verify cleanup completes. Add a validating admission rule and test behavior during a webhook outage. [Extending Kubernetes](https://kubernetes.io/docs/concepts/extend-kubernetes/) · [API aggregation](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/)

### Stateful workloads and failover

Follow [the Consul and PostgreSQL recovery build](deep-dives/stateful-recovery.md) to exercise a live failover.

Deploy a Consul quorum with stable StatefulSet identities and dynamically provisioned PVCs. Map each PVC to its PV and StorageClass and document its reclaim policy. Replace a Pod and verify that it rejoins with its original claim. For a separate exercise, run a disposable replicated database, write a marker, stop the active primary, and verify which writes survive promotion. Show that the old primary cannot accept writes after it returns. Record actual client recovery time and any lost writes so the failover claim has evidence.
