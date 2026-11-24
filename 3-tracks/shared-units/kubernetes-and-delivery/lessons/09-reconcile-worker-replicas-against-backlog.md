# 09 Reconcile worker replicas against backlog

A controller should change worker counts without permission to edit a Pod template. Read the Core 03 queue-depth gauge, which counts durable waiting rows. Reject absent or invalid samples. Compute a bounded recommendation and wait for three consecutive scale-down recommendations before reducing capacity.

## Build it

### Step 1. Test the policy without a cluster

Try a large backlog, three scale-down readings, and invalid data. State the minimum and maximum worker counts.

<details>
<summary>Hint</summary>

Treat NaN and fractional counts as unavailable readings.

</details>

<details>
<summary>Type-along files</summary>

Create `delivery/internal/scaling/policy.go`.

<!-- file: delivery/internal/scaling/policy.go -->
~~~go
package scaling

import (
	"bufio"
	"errors"
	"io"
	"math"
	"strconv"
	"strings"
)

func Backlog(r io.Reader) (int, error) {
	s := bufio.NewScanner(r)
	for s.Scan() {
		raw, ok := strings.CutPrefix(s.Text(), "jobs_queue_depth ")
		if !ok {
			continue
		}
		n, err := strconv.ParseFloat(raw, 64)
		if err != nil || math.IsNaN(n) || math.IsInf(n, 0) || n < 0 || n > 1e6 || math.Trunc(n) != n {
			return 0, errors.New("queue depth is missing a usable sample")
		}
		return int(n), nil
	}
	if err := s.Err(); err != nil {
		return 0, err
	}
	return 0, errors.New("queue depth was absent")
}

type Policy struct{ quiet int }

func (p *Policy) Recommend(current, backlog int) int {
	desired := min(4, 1+backlog/3)
	if desired >= current {
		p.quiet = 0
		return desired
	}
	p.quiet++
	if p.quiet < 3 {
		return current
	}
	p.quiet = 0
	return desired
}

func (p *Policy) Reset() { p.quiet = 0 }
~~~

Create `delivery/internal/scaling/policy_test.go`.

<!-- file: delivery/internal/scaling/policy_test.go -->
~~~go
package scaling

import (
	"strings"
	"testing"
)

func TestPolicy(t *testing.T) {
	var p Policy
	if p.Recommend(1, 100) != 4 || p.Recommend(4, 0) != 4 || p.Recommend(4, 0) != 4 || p.Recommend(4, 0) != 1 {
		t.Fatal("expected a bounded scale-up and three samples before scale-down")
	}
	for _, s := range []string{"jobs_queue_depth NaN", "jobs_queue_depth -1", "nothing", "jobs_queue_depth 1.5"} {
		if _, err := Backlog(strings.NewReader(s)); err == nil {
			t.Fatal("invalid sample accepted", s)
		}
	}
	n, err := Backlog(strings.NewReader("jobs_queue_depth 5"))
	if n != 5 || err != nil {
		t.Fatal(n, err)
	}
	t.Log("bounded recommendations, stabilized scale-down, and refused invalid readings")
}
~~~

</details>
### Step 2. Reconcile one Scale object

Read the projected API credentials, compare the live and desired counts, and update the worker scale subresource with the observed resource version. Leave the replicas field to the controller once it is enabled.

<details>
<summary>Hint</summary>

A conflict is a reason to reread on the next pass. Limit the Role to the worker by name.

</details>

<details>
<summary>Type-along files</summary>

Create `delivery/cmd/scale-worker/main.go`.

<!-- file: delivery/cmd/scale-worker/main.go -->
~~~go
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"switchyard/delivery/internal/scaling"
)

type scale struct {
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`
	Metadata   struct {
		Name            string `json:"name"`
		Namespace       string `json:"namespace"`
		ResourceVersion string `json:"resourceVersion"`
	} `json:"metadata"`
	Spec struct {
		Replicas int `json:"replicas"`
	} `json:"spec"`
}

type controller struct {
	api                          *http.Client
	http                         *http.Client
	endpoint, metrics, tokenPath string
	policy                       scaling.Policy
}

func (c *controller) ask(ctx context.Context, method, token string, body []byte) (*http.Response, error) {
	r, err := http.NewRequestWithContext(ctx, method, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Content-Type", "application/json")
	return c.api.Do(r)
}

func (c *controller) readBacklog(ctx context.Context) (int, error) {
	r, err := http.NewRequestWithContext(ctx, http.MethodGet, c.metrics, nil)
	if err != nil {
		return 0, err
	}
	res, err := c.http.Do(r)
	if err != nil {
		return 0, err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return 0, fmt.Errorf("metrics status %d", res.StatusCode)
	}
	return scaling.Backlog(io.LimitReader(res.Body, 1<<20))
}

func (c *controller) reconcile(ctx context.Context) error {
	current, err := c.readBacklog(ctx)
	if err != nil {
		c.policy.Reset()
		return err
	}
	token, err := os.ReadFile(c.tokenPath)
	if err != nil {
		return err
	}
	t := strings.TrimSpace(string(token))
	res, err := c.ask(ctx, http.MethodGet, t, nil)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return fmt.Errorf("read scale: HTTP %d", res.StatusCode)
	}
	var observed scale
	if err := json.NewDecoder(io.LimitReader(res.Body, 64<<10)).Decode(&observed); err != nil {
		return err
	}
	if observed.Metadata.ResourceVersion == "" {
		return errors.New("scale response missing resourceVersion")
	}
	old := observed.Spec.Replicas
	desired := c.policy.Recommend(old, current)
	if old == desired {
		return nil
	}
	observed.Spec.Replicas = desired
	body, err := json.Marshal(observed)
	if err != nil {
		return err
	}
	put, err := c.ask(ctx, http.MethodPut, t, body)
	if err != nil {
		return err
	}
	defer put.Body.Close()
	io.Copy(io.Discard, io.LimitReader(put.Body, 64<<10))
	if put.StatusCode == 409 {
		return nil
	} // A later observation recomputes intent.
	if put.StatusCode != 200 {
		return fmt.Errorf("write scale: HTTP %d", put.StatusCode)
	}
	log.Printf("worker replicas %d -> %d (backlog=%d)", old, desired, current)
	return nil
}

func main() {
	metrics := flag.String("metrics", "http://jobs:8080/metrics", "Core 03 job metrics")
	flag.Parse()
	mount := "/var/run/secrets/kubernetes.io/serviceaccount"
	roots := x509.NewCertPool()
	ca, err := os.ReadFile(filepath.Join(mount, "ca.crt"))
	if err != nil || !roots.AppendCertsFromPEM(ca) {
		log.Fatal("cannot read API trust root")
	}
	ns, err := os.ReadFile(filepath.Join(mount, "namespace"))
	if err != nil {
		log.Fatal(err)
	}
	c := &controller{api: &http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{
		TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}}},
		http: &http.Client{Timeout: 2 * time.Second}, metrics: *metrics, tokenPath: filepath.Join(mount, "token"),
		endpoint: "https://kubernetes.default.svc/apis/apps/v1/namespaces/" + strings.TrimSpace(string(ns)) + "/deployments/worker/scale"}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		if err := c.reconcile(ctx); err != nil && ctx.Err() == nil {
			log.Printf("reconcile: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
~~~

Create `chart/templates/scaler.yaml`.

<!-- file: chart/templates/scaler.yaml -->
~~~yaml
{{- if .Values.scaler.enabled }}
apiVersion: v1
kind: ServiceAccount
metadata: {name: worker-scaler}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: worker-scaler}
rules:
- apiGroups: [apps]
  resources: [deployments/scale]
  resourceNames: [worker]
  verbs: [get, update]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: worker-scaler}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: worker-scaler}
subjects:
- {kind: ServiceAccount, name: worker-scaler, namespace: {{ .Release.Namespace }}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: worker-scaler}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: worker-scaler}}
  template:
    metadata: {labels: {app: worker-scaler}}
    spec:
      serviceAccountName: worker-scaler
      securityContext: {{- include "delivery.podSecurity" . | nindent 8 }}
      containers:
      - name: scaler
        image: {{ .Values.image | quote }}
        imagePullPolicy: IfNotPresent
        securityContext: {{- include "delivery.security" . | nindent 10 }}
        command: [/app/scale-worker]
        resources:
          requests: {cpu: 15m, memory: 16Mi}
          limits: {memory: 96Mi}
{{- end }}
~~~

</details>

## Check it

~~~bash
(cd delivery && go vet ./... && go test -race -count=1 -v ./...) && helm lint chart --set scaler.enabled=true
~~~

<!-- run: (cd delivery && go vet ./... && go test -race -count=1 -v ./...) && helm lint chart --set scaler.enabled=true -->

The tests cover invalid samples, bounds, and scale-down delay. [Captured Go checks](../evidence/unit-tests.txt)

## Run locally

Build the full image and enable `scaler.enabled`. Submit a burst of long jobs. Check worker replicas and controller logs. Use `kubectl auth can-i update deployment/worker --subresource=scale --as=system:serviceaccount:delivery-steps:worker-scaler -n delivery-steps` to check the permission. Repeat without the subresource flag.
