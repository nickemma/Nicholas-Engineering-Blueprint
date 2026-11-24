# Build a Kubebuilder operator for batch Jobs

Start with the [disposable platform cluster](workloads-and-rollouts.md). The goal is for a `Report` custom resource to create exactly one batch Job and clean up on deletion. The API server stores the CRD object. A separate controller reacts to changes and continually checks actual state against desired state. [Kubebuilder project](https://github.com/kubernetes-sigs/kubebuilder)

## 1. Scaffold the API

With Kubebuilder v4.11.1 and Go installed, run both scaffold commands in an empty directory.

~~~~bash
kubebuilder init --domain blueprint.example --repo example.com/report-operator
kubebuilder create api --group batch --version v1alpha1 --kind Report --resource --controller
~~~~

Replace the generated type file. The message must be nonempty and immutable because a Kubernetes Job template captures the message when the Job is created. The status subresource holds a `Ready` condition for the observed generation.

Create `api/v1alpha1/report_types.go`.

<!-- file: api/v1alpha1/report_types.go -->
~~~~go
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type ReportSpec struct {
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=120
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="message is immutable"
	Message string `json:"message"`
}

type ReportStatus struct {
	// +listType=map
	// +listMapKey=type
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
type Report struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              ReportSpec   `json:"spec"`
	Status            ReportStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
type ReportList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Report `json:"items"`
}

func init() {
	SchemeBuilder.Register(&Report{}, &ReportList{})
}
~~~~

## 2. Reconcile desired state and handle deletion

Replace the generated reconciler. Use deterministic names to recognize objects on a second reconcile. Set the Job's controller reference to the Report, so Kubernetes can garbage-collect it. The ConfigMap stands in for an external allocation. The finalizer explicitly releases it before the Report disappears.

The annotation simulates a cleanup dependency that is temporarily unavailable. During that condition the controller leaves the finalizer in place and rechecks after a short interval. The UID check prevents a cleanup from deleting an allocation that belongs to another Report.

Create `internal/controller/report_controller.go`.

<!-- file: internal/controller/report_controller.go -->
~~~~go
package controller

import (
	"context"
	"fmt"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/events"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	"example.com/report-operator/api/v1alpha1"
)

const finalizer = "batch.blueprint.example/release-allocation"

type ReportReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	recorder events.EventRecorder
}

// +kubebuilder:rbac:groups=batch.blueprint.example,resources=reports,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=batch.blueprint.example,resources=reports/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=batch.blueprint.example,resources=reports/finalizers,verbs=update
// +kubebuilder:rbac:groups=batch,resources=jobs,verbs=get;list;watch;create
// +kubebuilder:rbac:groups="",resources=configmaps,verbs=get;list;watch;create;delete
// +kubebuilder:rbac:groups=events.k8s.io,resources=events,verbs=create;patch;update

func (r *ReportReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	var report v1alpha1.Report
	if err := r.Get(ctx, req.NamespacedName, &report); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	if !report.DeletionTimestamp.IsZero() {
		return r.release(ctx, &report)
	}
	if controllerutil.AddFinalizer(&report, finalizer) {
		return ctrl.Result{RequeueAfter: time.Second}, r.Update(ctx, &report)
	}

	if err := r.ensureAllocation(ctx, &report); err != nil {
		return ctrl.Result{}, err
	}
	job, err := r.job(ctx, &report)
	if err != nil {
		return ctrl.Result{}, err
	}
	condition := metav1.Condition{
		Type: "Ready", Status: metav1.ConditionFalse,
		Reason: "JobPending", Message: "Waiting for the reporting Job",
		ObservedGeneration: report.Generation,
	}
	if job.Status.Succeeded == 1 {
		condition.Status = metav1.ConditionTrue
		condition.Reason = "JobSucceeded"
		condition.Message = "The reporting Job completed"
	}
	if meta.SetStatusCondition(&report.Status.Conditions, condition) {
		if err := r.Status().Update(ctx, &report); err != nil {
			return ctrl.Result{}, err
		}
		if condition.Status == metav1.ConditionTrue {
			r.recorder.Eventf(&report, job, "Normal", "JobSucceeded", "Reconcile", "Job %s completed", job.Name)
		}
	}
	return ctrl.Result{}, nil
}

func allocationKey(report *v1alpha1.Report) client.ObjectKey {
	return client.ObjectKey{Namespace: report.Namespace, Name: "allocation-" + report.Name}
}

func (r *ReportReconciler) ensureAllocation(ctx context.Context, report *v1alpha1.Report) error {
	key := allocationKey(report)
	allocation := corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace},
		Data:       map[string]string{"reportUID": string(report.UID)},
	}
	err := r.Create(ctx, &allocation)
	if !apierrors.IsAlreadyExists(err) {
		return err
	}
	if err := r.Get(ctx, key, &allocation); err != nil {
		return err
	}
	if allocation.Data["reportUID"] != string(report.UID) {
		return fmt.Errorf("allocation %s belongs to a different report", key)
	}
	return nil
}

func (r *ReportReconciler) release(ctx context.Context, report *v1alpha1.Report) (ctrl.Result, error) {
	if !controllerutil.ContainsFinalizer(report, finalizer) {
		return ctrl.Result{}, nil
	}
	if report.Annotations["batch.blueprint.example/block-release"] == "yes" {
		return ctrl.Result{RequeueAfter: 2 * time.Second}, nil
	}
	var allocation corev1.ConfigMap
	err := r.Get(ctx, allocationKey(report), &allocation)
	if client.IgnoreNotFound(err) != nil {
		return ctrl.Result{}, err
	}
	if err == nil && allocation.Data["reportUID"] == string(report.UID) {
		uid := allocation.UID
		err = r.Delete(ctx, &allocation, client.Preconditions{UID: &uid})
		if client.IgnoreNotFound(err) != nil {
			return ctrl.Result{}, err
		}
	}
	controllerutil.RemoveFinalizer(report, finalizer)
	return ctrl.Result{}, r.Update(ctx, report)
}

func (r *ReportReconciler) job(ctx context.Context, report *v1alpha1.Report) (*batchv1.Job, error) {
	key := client.ObjectKey{Namespace: report.Namespace, Name: report.Name}
	var existing batchv1.Job
	err := r.Get(ctx, key, &existing)
	if err == nil {
		if !metav1.IsControlledBy(&existing, report) {
			return nil, fmt.Errorf("job %s has a different owner", key)
		}
		return &existing, nil
	}
	if !apierrors.IsNotFound(err) {
		return nil, err
	}
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace},
		Spec: batchv1.JobSpec{
			Template: corev1.PodTemplateSpec{
				Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyNever,
					Containers: []corev1.Container{{
						Name: "report", Image: "busybox:1.37",
						Command: []string{"printf", "%s\n", report.Spec.Message},
					}},
				},
			},
		},
	}
	if err := controllerutil.SetControllerReference(report, job, r.Scheme); err != nil {
		return nil, err
	}
	return job, r.Create(ctx, job)
}

func (r *ReportReconciler) SetupWithManager(mgr ctrl.Manager) error {
	r.recorder = mgr.GetEventRecorder("report-controller")
	return ctrl.NewControllerManagedBy(mgr).
		For(&v1alpha1.Report{}).
		Owns(&batchv1.Job{}).
		Complete(r)
}
~~~~

## 3. Verify the CRD, controller and cleanup

The check starts the built manager using the lab kubeconfig, installs the generated CRD, and creates a Report in a new namespace. It waits for the Ready status, checks the Job's logs, and triggers a second reconcile. It requires the same Job UID. Finally it blocks cleanup, observes deletion pending, restores cleanup and checks both the allocation and dependent Job disappear.

Create `report.yaml`.

<!-- file: report.yaml -->
~~~~yaml
apiVersion: batch.blueprint.example/v1alpha1
kind: Report
metadata:
  name: daily
spec:
  message: daily report generated
~~~~

Create `check-operator.sh`.

<!-- file: check-operator.sh -->
~~~~bash
#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?Point KUBECONFIG at the disposable kind cluster}"
test "$(kubectl config current-context)" = kind-blueprint-platform-build
namespace="operator-lab-${RANDOM}-$$"
kubectl create namespace "$namespace"
k() { kubectl -n "$namespace" "$@"; }
cleanup() {
  if [[ -n "${manager:-}" ]]; then
    k annotate report/daily batch.blueprint.example/block-release- >/dev/null 2>&1 || true
    k delete report/daily --ignore-not-found --timeout=15s >/dev/null 2>&1 || true
    kill "$manager" 2>/dev/null || true
    wait "$manager" 2>/dev/null || true
  fi
  kubectl delete namespace "$namespace" --wait=false >/dev/null
}
trap cleanup EXIT

kubectl apply -f config/crd/bases/batch.blueprint.example_reports.yaml
kubectl wait --for=condition=Established crd/reports.batch.blueprint.example --timeout=30s
./manager --health-probe-bind-address=0 --metrics-bind-address=0 > manager.log 2>&1 &
manager=$!

k apply -f report.yaml
k wait --for=condition=Ready report/daily --timeout=90s
test "$(k logs job/daily)" = "daily report generated"
uid="$(k get job/daily -o jsonpath='{.metadata.uid}')"
k annotate report/daily blueprint.example/reconcile=again
k apply -f report.yaml
test "$(k get job -o name)" = job.batch/daily
test "$(k get job/daily -o jsonpath='{.metadata.uid}')" = "$uid"
k get events --field-selector=reason=JobSucceeded
echo "Ready Report owns one completed Job after repeated reconciliation"

k annotate report/daily batch.blueprint.example/block-release=yes
k delete report/daily --wait=false --cascade=background
test -n "$(k get report/daily -o jsonpath='{.metadata.deletionTimestamp}')"
k get configmap/allocation-daily -o name
k annotate report/daily batch.blueprint.example/block-release-
k wait --for=delete report/daily --timeout=30s
test -z "$(k get configmap/allocation-daily --ignore-not-found -o name)"
k wait --for=delete job/daily --timeout=30s
echo "finalizer paused deletion; release removed the allocation and garbage collection removed the Job"
~~~~

<!-- run: test -z "$(gofmt -l api/v1alpha1/report_types.go internal/controller/report_controller.go)" && bash -n check-operator.sh -->
~~~~bash
test -z "$(gofmt -l api/v1alpha1/report_types.go internal/controller/report_controller.go)" && bash -n check-operator.sh
~~~~

~~~~bash
make generate manifests
go build -o manager ./cmd
bash check-operator.sh
~~~~

~~~~text
Ready Report owns one completed Job after repeated reconciliation
configmap/allocation-daily
finalizer paused deletion; release removed the allocation and garbage collection removed the Job
~~~~

Inspect the generated Role and the `JobSucceeded` event. The lab manager runs locally with your isolated cluster identity. If deployed into the cluster, bind the generated permissions to its service account. For a worked comparison, inspect how the CloudNativePG operator manages database instances and admission in [the recovery build](stateful-recovery.md).
