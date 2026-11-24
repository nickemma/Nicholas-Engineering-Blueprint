# 06 Build once and promote by digest

A tag can refer to different bytes over time. The image tested as a candidate must be the image deployed after approval. The digest identifies the bytes. A signature lets you check who authorized the digest, and an attestation ties the inventory to it.

## Build it

### Step 1. Publish to the lab registry

Configure a loopback registry and a containerd mirror in the disposable kind nodes. Push a tag for discoverability and record the manifest digest as release output.

<details>
<summary>Hint</summary>

Docker pushes through the loopback binding. Inside a kind node, the mirror reaches the registry over the local Docker network.

</details>

<details>
<summary>Type-along files</summary>

Create `ops/registry.sh`.

<!-- file: ops/registry.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
cluster=$1
port=$2
name="$cluster-registry"
docker run -d --name "$name" --publish "127.0.0.1:$port:5000" registry:3 >/dev/null
docker network connect kind "$name"
while IFS= read -r node; do
  path="/etc/containerd/certs.d/localhost:$port"
  docker exec "$node" mkdir -p "$path"
  printf '[host."http://%s:5000"]\n  capabilities = ["pull", "resolve"]\n' "$name" |
    docker exec -i "$node" tee "$path/hosts.toml" >/dev/null
done < <(kind get nodes --name "$cluster")
printf 'lab registry: localhost:%s\n' "$port"
~~~

Create `ops/publish.sh`.

<!-- file: ops/publish.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
local_image=$1
target=$2
if [[ ! "$target" =~ ^localhost:[0-9]+/[a-z0-9/-]+:[A-Za-z0-9._-]+$ ]]; then
  echo "supply a tag in the local lab registry" >&2
  exit 2
fi
repository=${target%:*}
docker tag "$local_image" "$target"
docker push "$target" >&2
docker image inspect "$target" --format '{{range .RepoDigests}}{{println .}}{{end}}' |
  awk -v prefix="$repository@sha256:" 'index($0, prefix) == 1 && length($0) == length(prefix) + 64 {print; found=1; exit} END {exit !found}'
~~~

</details>
### Step 2. Verify the signature and SBOM

Generate a lab key pair outside source control. Use Syft to inventory the image by digest. Have Cosign attach the signature and SPDX attestation. Verify with the public key before changing Kubernetes state.

<details>
<summary>Hint</summary>

Pass the immutable reference to each command. The offline key and loopback registry belong to this lab.

</details>

<details>
<summary>Type-along files</summary>

Create `ops/sign.sh`.

<!-- file: ops/sign.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
ref=$1
key=$2
if [[ ! "$ref" =~ ^localhost:[0-9]+/[a-z0-9/-]+@sha256:[a-f0-9]{64}$ ]]; then
  echo "sign only a digest in the local lab registry" >&2
  exit 2
fi
sbom=$(mktemp)
trap 'rm -f -- "$sbom"' EXIT
SYFT_CHECK_FOR_APP_UPDATE=false syft "registry:$ref" -o spdx-json > "$sbom"
cosign sign --yes --key "$key" --use-signing-config=false --tlog-upload=false --allow-insecure-registry "$ref"
cosign attest --yes --key "$key" --use-signing-config=false --tlog-upload=false --allow-insecure-registry \
  --type spdxjson --predicate "$sbom" "$ref"
~~~

Create `ops/verify-release.sh`.

<!-- file: ops/verify-release.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
ref=$1
key=$2
if [[ ! "$ref" =~ ^localhost:[0-9]+/[a-z0-9/-]+@sha256:[a-f0-9]{64}$ ]]; then
  echo "expected a local image digest" >&2
  exit 2
fi
cosign verify --key "$key" --insecure-ignore-tlog --allow-insecure-registry "$ref" >/dev/null
cosign verify-attestation --key "$key" --insecure-ignore-tlog --allow-insecure-registry \
  --type spdxjson "$ref" >/dev/null
printf 'signature and SPDX attestation verified for %s\n' "$ref"
~~~

</details>
### Step 3. Separate packaging from promotion

Pass the release script's digest file to the deployment job. Compare the candidate's current image with that digest and wait for readiness before touching stable.

<details>
<summary>Hint</summary>

Build and sign in the release job. Keep the private key away from the promoter. Serialize promotion in this lab.

</details>

<details>
<summary>Type-along files</summary>

Create `ops/ci-release.sh`.

<!-- file: ops/ci-release.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
local_image=$1
target_tag=$2
signing_key=$3
public_key=$4
release_file=$5

(cd delivery && go test -race -count=1 ./...)
bash ops/build-image.sh "$local_image"
ref=$(bash ops/publish.sh "$local_image" "$target_tag")
bash ops/sign.sh "$ref" "$signing_key"
bash ops/verify-release.sh "$ref" "$public_key"
printf '%s\n' "$ref" > "$release_file"
~~~

Create `ops/promote.sh`.

<!-- file: ops/promote.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
namespace=$1
ref=$2
key=$3
bash ops/verify-release.sh "$ref" "$key"
candidate=$(kubectl -n "$namespace" get deployment frontend-canary -o 'jsonpath={.spec.template.spec.containers[0].image}')
if [[ "$candidate" != "$ref" ]]; then
  echo 'the running candidate must use the approved digest' >&2
  exit 2
fi
kubectl -n "$namespace" rollout status deployment/frontend-canary --timeout=15s
kubectl -n "$namespace" set image deployment/frontend-stable "frontend=$ref"
kubectl -n "$namespace" rollout status deployment/frontend-stable --timeout=90s
~~~

</details>

## Check it

~~~bash
for f in ops/{registry,publish,sign,verify-release,ci-release,promote}.sh; do bash -n "$f" || exit; done
~~~

<!-- run: for f in ops/{registry,publish,sign,verify-release,ci-release,promote}.sh; do bash -n "$f" || exit; done -->

The offline check validates the shell scripts. The live gate tests verification, an unsigned control, and refusal to promote a failed candidate.

## Run locally

Follow the [gate guide](../gate/README.md). The lab verifies against a local public key. A production pipeline can use transparency logging and managed signing credentials. [Cosign verification](https://docs.sigstore.dev/cosign/verifying/verify/) · [kind local registry](https://kind.sigs.k8s.io/docs/user/local-registry/)
