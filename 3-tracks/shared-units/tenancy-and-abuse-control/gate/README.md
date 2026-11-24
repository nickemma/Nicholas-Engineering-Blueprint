# Tenancy and abuse control gate

From the Blueprint checkout, rebuild the lessons and run the live gate.

~~~bash
SWITCHYARD_TENANCY_LIVE=1 python3 scripts/replay_lessons.py 3-tracks/shared-units/tenancy-and-abuse-control
~~~

From the learner directory, run the same checks on the code you built.

~~~bash
SWITCHYARD_TENANCY_LIVE=1 bash "$blueprint/3-tracks/shared-units/tenancy-and-abuse-control/gate/run.sh" "$PWD"
~~~

Leaving out `SWITCHYARD_TENANCY_LIVE=1` runs formatting, vet, and the race-enabled token and local bucket checks. The live gate provisions `postgres:17` and `redis:8` on dynamically assigned loopback ports, with a distinct PostgreSQL runtime login. It removes the temporary services and their anonymous volumes after the run.

Check these outcomes in the [reference capture](../evidence/README.md).

1. The issuer refuses unknown credentials. The verifier checks issuer, audience, expiry, and signature. Both keys verify during rotation overlap.
2. The CLI issues a token, publishes its public keys, and uses the token to create and read a job.
3. The API enforces reader and writer permissions and finds jobs only within the authenticated tenant. The dedicated database runtime login also sees zero fixture rows and cannot insert without tenant context.
4. Two API instances sharing Redis admit 2 of 16 reads for the busy tenant and return 429 with Retry-After for the other 14. The quiet tenant still reads its own job.
5. Pausing Redis makes the quota step return 503 before the pause ends. The negative control swaps in one local bucket per API instance and the same quota assertion catches the four accepted reads.

## Try the API manually

Use a fresh disposable PostgreSQL database. Run these commands from the learner directory with an operator connection string in `TENANT_OWNER_DB_URL`. Set `TENANT_DB_URL` to the connection string for `tenant_api` using the generated password and the same database and host.

~~~bash
tenant_role_password=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
psql "$TENANT_OWNER_DB_URL" -v ON_ERROR_STOP=1 -v runtime_password="$tenant_role_password" <<'SQL'
CREATE ROLE tenant_api LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD :'runtime_password';
SQL
psql "$TENANT_OWNER_DB_URL" -v ON_ERROR_STOP=1 -f db/schema.sql
~~~

Generate a client with a new fixture secret, then launch the loopback server.

~~~bash
python3 - <<'PY'
import json
import os
import secrets
os.umask(0o077)
with open("clients.json", "x") as file:
    json.dump({"acme-lab": {"tenant": "acme", "role": "writer", "secret": secrets.token_hex(24)}}, file)
PY
export TENANT_CREDENTIALS_FILE="$PWD/clients.json"
go run ./cmd/tenant-lab
~~~

In a second shell in the learner directory, run this script. Expect 201 for the create and the saved job for the read.

~~~bash
python3 - <<'PY'
import base64
import json
from urllib.request import Request, urlopen

base = "http://127.0.0.1:8080"
with open("clients.json") as file:
    secret = json.load(file)["acme-lab"]["secret"]
basic = base64.b64encode(f"acme-lab:{secret}".encode()).decode()
with urlopen(Request(base + "/token", method="POST", headers={"Authorization": "Basic " + basic}), timeout=5) as reply:
    token = json.load(reply)["access_token"]
headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
create = Request(base + "/jobs", data=b'{"id":"demo","name":"Demo job"}', headers=headers)
with urlopen(create, timeout=5) as reply:
    print(reply.status)
with urlopen(Request(base + "/jobs/demo", headers=headers), timeout=5) as reply:
    print(json.load(reply))
PY
~~~

Set `TENANT_QUOTA_MODE=redis` and `TENANT_REDIS_URL` when starting the server to use a disposable Redis instance. The CLI uses a new signing key at startup. The gate's two API instances start from the same trusted key snapshot so they can accept the same token.
