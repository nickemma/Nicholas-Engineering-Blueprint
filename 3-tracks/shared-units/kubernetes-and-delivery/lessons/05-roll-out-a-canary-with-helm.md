# 05 Roll out a canary with Helm

## The problem

A candidate can start while failing readiness. A generic process check can pass even though the release cannot serve a request.

## The pattern

Keep separate canary and stable Deployment selectors and route only explicit candidate traffic to the canary. Keep one backend jobs coordinator. Render both Helm inputs before applying. Compare the desired image, observed readiness, and responses from each route. Promotion is a separate operation.

### Step 1. Render the failure

~~~bash
helm template delivery chart --set canaryFault=true --show-only templates/frontend.yaml
~~~

Find `-fail-ready` on the canary's container. Verify the stable Deployment still uses its original image setting and has no fault flag.

### Step 2. Check the running rollout

> **Run locally.** Use the disposable step namespace and your assembled image.

~~~bash
helm upgrade delivery chart -n delivery-steps --reuse-values --set canaryFault=true
kubectl -n delivery-steps get pods -l app=frontend-canary
kubectl -n delivery-steps rollout status deployment/frontend-canary --timeout=15s
~~~

Expect the canary process to run and rollout status to time out. The stable path should still return its original job value. Restore with `--set canaryFault=false` and check candidate readiness again. The next lesson makes the promotion command enforce the image and readiness checks.


## Check it

~~~bash
helm lint chart && helm template delivery chart --set canaryFault=true --show-only templates/frontend.yaml >/dev/null
~~~

<!-- run: helm lint chart && helm template delivery chart --set canaryFault=true --show-only templates/frontend.yaml >/dev/null -->

The rendered release keeps stable and canary as distinct Deployments and Services.
