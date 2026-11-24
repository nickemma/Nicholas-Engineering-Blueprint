# 03 Deploy the jobs path with persistent storage

## The problem

Pod replacement changes the process. Migration order, durable storage, and access credentials still have to line up so existing jobs remain readable.

## Build it

### Step 1. Reuse the Core 03 migrations

Stage the existing SQL into the Helm chart. The ConfigMap stores each file as a key. The Job maps migration keys back into the subdirectory expected by psql.

<details>
<summary>Hint</summary>

Keep the SQL version history in Core 03. Use the same migration entry point as Compose.

</details>

<details>
<summary>Type-along files</summary>

Create `ops/stage-db.sh`.

<!-- file: ops/stage-db.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
mkdir -p chart/files/db/migrations
cp jobs/db/migrate.sql chart/files/db/
cp jobs/db/migrations/*.sql chart/files/db/migrations/
~~~

Create `chart/templates/database.yaml`.

<!-- file: chart/templates/database.yaml -->
~~~yaml
{{- if .Values.database.enabled }}
apiVersion: v1
kind: ConfigMap
metadata: {name: migrations}
data:
{{ (.Files.Glob "files/db/**").AsConfig | indent 2 }}
---
apiVersion: v1
kind: Service
metadata: {name: postgres}
spec:
  selector: {app: postgres}
  ports: [{name: pg, port: 5432, targetPort: pg}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: postgres}
spec:
  serviceName: postgres
  replicas: 1
  selector: {matchLabels: {app: postgres}}
  template:
    metadata: {labels: {app: postgres}}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: postgres
        image: {{ .Values.database.image | quote }}
        securityContext: {{- include "delivery.security" . | nindent 10 }}
        env:
        - {name: POSTGRES_USER, value: switchyard}
        - {name: POSTGRES_DB, value: switchyard}
        - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef: {name: {{ .Values.database.secret }}, key: password}
        ports: [{name: pg, containerPort: 5432}]
        readinessProbe:
          exec: {command: [pg_isready, -h, 127.0.0.1, -U, switchyard]}
          periodSeconds: 2
        volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
        resources:
          requests: {cpu: 100m, memory: 64Mi}
          limits: {memory: 512Mi}
  volumeClaimTemplates:
  - metadata: {name: data}
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests: {storage: 512Mi}
---
apiVersion: batch/v1
kind: Job
metadata: {name: migrate}
spec:
  activeDeadlineSeconds: 150
  template:
    metadata: {labels: {app: migrate}}
    spec:
      restartPolicy: OnFailure
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: migrate
        image: {{ .Values.database.image | quote }}
        securityContext: {{- include "delivery.security" . | nindent 10 }}
        command: [/bin/sh, -ec]
        args:
        - |
          until pg_isready -q -h postgres -U switchyard; do sleep 2; done
          exec psql -h postgres -U switchyard -d switchyard -X -v ON_ERROR_STOP=1 -f /db/migrate.sql
        env:
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef: {name: {{ .Values.database.secret }}, key: password}
        volumeMounts: [{name: sql, mountPath: /db, readOnly: true}]
      volumes:
      - name: sql
        configMap:
          name: migrations
          items:
          - {key: migrate.sql, path: migrate.sql}
          {{- range $path, $_ := .Files.Glob "files/db/migrations/*.sql" }}
          - {key: {{ base $path }}, path: {{ printf "migrations/%s" (base $path) }}}
          {{- end }}
{{- end }}
~~~

</details>
### Step 2. Generate lab secrets

Keep the database password and connection URL in a private local directory and create the Secret from files. The helper also creates the separate CAs and leaf certificates used next.

<details>
<summary>Hint</summary>

Run it once per fresh namespace. Kubernetes consumers refer to keys by name. The issuer's private key remains outside the Pods.

</details>

<details>
<summary>Type-along files</summary>

Create `ops/lab-secrets.sh`.

<!-- file: ops/lab-secrets.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
umask 077
namespace=$1
out=$2
domain=${3:-cluster.local}
mkdir -m 700 "$out"
bash core/ops/pki.sh "$out/gateway"
mkdir -m 700 "$out/peers"
(
  cd "$out/peers"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc -sha256 \
    -days 2 -subj '/CN=Switchyard peer lab CA' \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' -out ca.crt -keyout ca.key
  for i in 0 1 2; do
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
      -subj "/CN=metadata-$i" -keyout "$i.key" -out "$i.csr"
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:metadata-%s.metadata.%s.svc.%s,URI:urn:switchyard:peer:%s\n' \
      "$i" "$namespace" "$domain" "$((i+1))" > "$i.ext"
    openssl x509 -req -in "$i.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
      -days 1 -sha256 -extfile "$i.ext" -out "$i.crt"
  done
)
password=$(openssl rand -hex 18)
printf '%s' "$password" > "$out/db-password"
printf 'postgres://switchyard:%s@postgres:5432/switchyard?sslmode=disable' "$password" > "$out/db-url"
kubectl -n "$namespace" create secret generic switchyard-db \
  --from-file=password="$out/db-password" --from-file=url="$out/db-url"
kubectl -n "$namespace" create secret generic switchyard-gateway \
  --from-file="$out/gateway/ca.crt" --from-file="$out/gateway/gateway.crt" --from-file="$out/gateway/gateway.key"
kubectl -n "$namespace" create secret generic switchyard-peers --from-file="$out/peers/ca.crt" \
  --from-file="$out/peers/0.crt" --from-file="$out/peers/0.key" \
  --from-file="$out/peers/1.crt" --from-file="$out/peers/1.key" \
  --from-file="$out/peers/2.crt" --from-file="$out/peers/2.key"
~~~

</details>

## Check it

~~~bash
bash ops/stage-db.sh && helm lint chart && helm template delivery chart >/dev/null
~~~

<!-- run: bash ops/stage-db.sh && helm lint chart && helm template delivery chart >/dev/null -->

The database claim, migration Job, and API Secret reference all render. A Secret file is also generated for later metadata lessons.

## Run locally

In the step namespace, run `bash ops/lab-secrets.sh delivery-steps "$PWD/.lab/step-secrets"` once. Run `bash ops/stage-db.sh` and reinstall the chart with `--set database.enabled=true`. Wait for `job/migrate` to complete before submitting. Use the entry port-forward and the Core 03 request body `{"description":"delivery","duration_ms":0}` at `POST /jobs`. Poll the returned job ID until completion. Replace a worker Pod and read the same completed job again.

The first API may start before the migration completes. Observe the startup failure and retry, then inspect the migration Job. Treat successful migration and client success as separate checks.
