# 07 A supply chain for code and weights

A model file is executable input to a large native parser. Pin the image digest, use a safe weight format, restrict who can publish, scan dependencies, and establish who authorised these exact bytes. A checksum alone does not identify that person. Produce two SBOMs with [Syft](https://github.com/anchore/syft): one for the image and one inventory for the model directory. Record model origin, revision, license and tokenizer/template hashes in provenance. An inventory cannot prove what training data the publisher used.

Run the following in a release directory with Syft and [Cosign](https://docs.sigstore.dev/cosign/verifying/verify/) installed. Key generation is local practice; production keeps its signing identity in the release system, separate from deployment. Replace `IMAGE` with **your own built server image by digest**, not a tag, before publishing/signing. Do not sign an upstream image as if you built it.

~~~bash
cosign generate-key-pair
syft "$IMAGE" -o spdx-json > image.spdx.json
syft dir:weights --source-name model-weights --source-version release-1 \
  --select-catalogers file-metadata,digest -o spdx-json > weights.spdx.json
mv weights.spdx.json weights/weights.spdx.json
# Write weights/provenance.json with origin, revision, license, template/tokenizer
# hashes, build source revision and builder identity before the next command.
python3 - <<'PYCODE'
import hashlib, json
from pathlib import Path
p = Path('weights')
names = ['model.gguf', 'weights.spdx.json', 'provenance.json']
manifest = {'sha256': {n: hashlib.file_digest((p/n).open('rb'), 'sha256').hexdigest() for n in names}}
(p/'manifest.json').write_text(json.dumps(manifest, sort_keys=True))
PYCODE
cosign sign-blob --key cosign.key --bundle weights/manifest.sigstore.json weights/manifest.json
cosign sign --key cosign.key "$IMAGE"
cosign attest --key cosign.key --predicate image.spdx.json --type spdxjson "$IMAGE"
~~~

The signed manifest binds the weights, inventory and provenance together. Verify all three before opening the server port:


<!-- file: deploy/inference/verify-weights.sh -->
~~~bash
#!/usr/bin/env bash
# Mounted key and artifacts must be read-only; invoke before exec-ing the server.
set -euo pipefail
: "${WEIGHTS_DIR:?}" "${TRUSTED_KEY:?}" "${EXPECTED_MANIFEST_SHA256:?}"
cd "$WEIGHTS_DIR"
cosign verify-blob --key "$TRUSTED_KEY" --bundle manifest.sigstore.json manifest.json
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
manifest_path = Path('manifest.json')
actual = hashlib.file_digest(manifest_path.open('rb'), 'sha256').hexdigest()
if actual != os.environ['EXPECTED_MANIFEST_SHA256']:
    raise SystemExit('unauthorised manifest digest')
manifest = json.loads(manifest_path.read_text())
for name in ('model.gguf', 'weights.spdx.json', 'provenance.json'):
    path = Path(name)
    digest = hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
    if digest != manifest['sha256'][name]:
        raise SystemExit(f'digest mismatch: {name}')
print('verified model, SBOM and provenance')
PY
~~~

<!-- run: bash -n deploy/inference/verify-weights.sh -->

Build a derived server image containing this verifier, Python and the pinned Cosign binary. Its entrypoint runs the verifier and `exec`s llama-server only after success. Set `EXPECTED_MANIFEST_SHA256` from the reviewed release configuration (the SHA-256 of the exact authorised manifest), and mount the public trust key and artifacts read-only; the signing private key never enters the cluster. Put verification in the entrypoint, rather than just an init container that checks a mutable volume long before the server reads it. Use an immutable model artifact or a private copy if another process can change the volume: read-only in one container does not prevent another writer from changing a PVC.

Deploy [Sigstore policy-controller](https://docs.sigstore.dev/policy-controller/overview/) in the lab cluster, label `switchyard` for inclusion, and install a `ClusterImagePolicy` matching your registry prefix with a `key.data` authority containing `cosign.pub`. Set `no-match-policy: deny` in its config and `failurePolicy: Fail` on the validating webhook. Keep an explicit trusted policy for the verifier image too. Test on a disposable namespace first; a policy that matches no workload is not enforcement.

Create the image policy from this template. Replace both the registry glob and the entire key placeholder before applying; a placeholder is not a trust root. Install and enable policy-controller first, following its version-matched chart instructions. The registry policy must cover every container and init container admitted to the enforced namespace; scope the disposable test namespace accordingly.

<!-- file: deploy/inference/image-policy.template.yaml -->
~~~yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: switchyard-inference
spec:
  images:
    - glob: "ghcr.io/YOUR_ORG/switchyard-inference**"
  authorities:
    - key:
        data: |
          REPLACE_WITH_CONTENTS_OF_COSIGN_PUB
~~~
~~~bash
# After replacing the template values and installing the controller:
kubectl label namespace switchyard policy.sigstore.dev/include=true --overwrite
kubectl apply -f deploy/inference/image-policy.template.yaml
# Verify fail-closed webhook/no-match settings before the negative cases.
~~~

Admission verifies **images**. The entrypoint verifies **weights**; admission does not inspect arbitrary PVC bytes. Both must pass. Also bind the allowed model manifest digest into the deployment's reviewed release configuration: a valid signature for an older authorised model is otherwise a possible rollback. Archive the release bundle, SBOMs, scan results and manifest digest. Key compromise and revocation need a separate trust-key rotation runbook.

**Break it, with evidence:** deploy an unsigned image (admission must reject); change one byte of `model.gguf` while keeping its bundle (startup must refuse); remove the bundle (startup must refuse); replace the public key with another key (verification must fail); restore the authorised artifact (readiness must return). Capture each command, exit status and event. The [dated CPU evidence](../evidence/2026-11-07/report.md) exercises the weight verification/refusal cases and recovery. The [platform validation report](../evidence/platform-validation/report.md) adds live image-admission, startup-verification and rollback evidence; the local signer is still a lab trust authority. Never paste the private key into the transcript.

## Bind the verifier to the reviewed release

The live deployment uses this stricter entrypoint. It copies the input artifacts into a private `emptyDir`, verifies that copy, and opens the fixed server port only after success. The authorised manifest digest is compiled into the launcher; the image contains the public model key and public Sigstore trust root. Pod environment variables and arguments cannot select another key, model or manifest. The running model reads the verified private copy, so a later write to the source PVC does not change the file it opens.

<!-- file: deploy/inference/launcher.go -->
~~~go
// A release-bound entrypoint: copy, verify, then start the fixed model server.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

var expectedManifest string // set by the reviewed build, never from Pod env
func fatal(err error)       { fmt.Fprintln(os.Stderr, "model startup refused:", err); os.Exit(1) }
func digest(path string) (string, error) {
	f, e := os.Open(path)
	if e != nil {
		return "", e
	}
	defer f.Close()
	h := sha256.New()
	if _, e = io.Copy(h, f); e != nil {
		return "", e
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
func main() {
	names := []string{"manifest.json", "manifest.sigstore.json", "model.gguf", "weights.spdx.json", "provenance.json"}
	for _, name := range names {
		src, e := os.Open(filepath.Join("/models", name))
		if e != nil {
			fatal(e)
		}
		dst, e := os.OpenFile(filepath.Join("/verified", name), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
		if e != nil {
			src.Close()
			fatal(e)
		}
		_, e = io.Copy(dst, src)
		src.Close()
		closeErr := dst.Close()
		if e != nil {
			fatal(e)
		}
		if closeErr != nil {
			fatal(closeErr)
		}
	}
	got, e := digest("/verified/manifest.json")
	if e != nil {
		fatal(e)
	}
	if len(expectedManifest) != 64 || got != expectedManifest {
		fatal(fmt.Errorf("unauthorised manifest digest"))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/local/bin/cosign", "verify-blob", "--key", "/trust/model.pub", "--trusted-root", "/trust/trusted_root.json", "--bundle", "/verified/manifest.sigstore.json", "/verified/manifest.json")
	cmd.Env = []string{"PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/tmp"}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if e = cmd.Run(); e != nil {
		fatal(e)
	}
	var m struct {
		SHA256 map[string]string `json:"sha256"`
	}
	data, e := os.ReadFile("/verified/manifest.json")
	if e != nil {
		fatal(e)
	}
	if e = json.Unmarshal(data, &m); e != nil {
		fatal(e)
	}
	for _, name := range []string{"model.gguf", "weights.spdx.json", "provenance.json"} {
		got, e = digest(filepath.Join("/verified", name))
		if e != nil {
			fatal(e)
		}
		if got != m.SHA256[name] {
			fatal(fmt.Errorf("digest mismatch: %s", name))
		}
	}
	for _, name := range names {
		if e = os.Chmod(filepath.Join("/verified", name), 0444); e != nil {
			fatal(e)
		}
	}
	fmt.Println("verified private copy: model, SBOM, provenance and authorised manifest")
	args := []string{"/app/llama-server", "-m", "/verified/model.gguf", "--host", "0.0.0.0", "--port", "8080", "-c", "4096", "-t", "2", "--parallel", "1", "--metrics"}
	if e = syscall.Exec(args[0], args, []string{"PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/tmp", "LD_LIBRARY_PATH=/app"}); e != nil {
		fatal(e)
	}
}
~~~

<!-- run: CGO_ENABLED=0 go build -o /tmp/serve-launcher-check deploy/inference/launcher.go -->

For the release build, set `-ldflags "-X main.expectedManifest=$MANIFEST_SHA256"` to the reviewed manifest hash. Copy the compiled launcher and checksum-verified Cosign binary to `/usr/local/bin/`, and the model public key and verified public Sigstore trust root to `/trust/model.pub` and `/trust/trusted_root.json` in your derived server image. Set its entrypoint to the launcher, clear the inherited CMD, and run as UID/GID 1000. Mount only `/models` read-only, a private disk-backed `/verified` emptyDir, and `/tmp`; grant the nonroot user access to its emptyDirs with `fsGroup`. Never put the private signing key into this build context.

Image signatures alone do not prevent a user from replacing the entrypoint. Add a namespace-scoped native `ValidatingAdmissionPolicy` that pins the approved image digest and rejects command, argument, environment, extra container and trust-path mount overrides. Use restricted Pod Security, a read-only root filesystem, no service-account token and deployment RBAC that prevents unreviewed pod exec/volume access. The [retained deployment and policy](../evidence/platform-validation/report.md) show the exact tested configuration. Model provenance still has the historical publisher-revision limitation; local signing does not repair it.

The pinned live tool pair was Cosign 3.1.4 with policy-controller 0.13.1 (chart 0.10.8). Its key-based image policy uses the legacy signature format. The isolated local registry test explicitly used `--use-signing-config=false --tlog-upload=false --new-bundle-format=false --registry-referrers-mode=legacy`; it tested the pinned public key, without claiming image transparency-log publication. The model's existing Sigstore bundle was verified separately against the public trust root. Production should adopt a reviewed signing configuration and compatible bundle policy rather than inherit these lab flags.

For a private TLS registry, this chart's `webhook.registryCaBundle` expects `{name: CONFIGMAP, key: ca.crt}`, not a map of PEM filenames. Inspect the rendered mount and test a valid signature as well as rejections: a TLS error that rejects every image does not demonstrate signature enforcement. The live negative cases now cover unsigned/wrong-key images, revoked trust, a fully stopped webhook, corrupted/missing weights, and verifier overrides.
