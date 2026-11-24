#!/usr/bin/env bash
set -euo pipefail
cd "${1:-.}"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
(cd delivery && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./...)
bash ops/stage-db.sh
settings=metadata.enabled=true,observability.enabled=true,scaler.enabled=true,networkPolicy=true
helm lint chart --set "$settings"
helm template delivery chart --namespace delivery-check --set "$settings" > "$work/rendered.yaml"
for marker in 'name: postgres' 'name: metadata' 'name: worker-scaler' 'name: prometheus'
do
  grep -q "$marker" "$work/rendered.yaml"
done
grep -q 'publishNotReadyAddresses: true' "$work/rendered.yaml"
grep -q 'resourceNames: \[worker\]' "$work/rendered.yaml"
echo 'chart rendered durable storage, peer discovery, observability, and scoped worker scaling'

# Replay approval logic with an unready candidate and no cluster mutations.
mkdir -p "$work/fixture"/{bin,ops}
cp ops/promote.sh "$work/fixture/ops/"
cat > "$work/fixture/ops/verify-release.sh" <<'MOCK'
exit 0
MOCK
cat > "$work/fixture/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$3 $4" in
  'get deployment') echo "$FIXTURE_REF" ;;
  'rollout status') exit 13 ;;
  'set image') echo 'stable changed' >> "$FIXTURE_SENTINEL" ;;
  *) exit 99 ;;
esac
MOCK
chmod +x "$work/fixture/bin/kubectl"
(
  cd "$work/fixture"
  export PATH="$PWD/bin:$PATH" FIXTURE_REF=localhost:5000/lab@sha256:fixture FIXTURE_SENTINEL="$PWD/mutation"
  test_guard() {
    local result=0
    bash ops/promote.sh test "$FIXTURE_REF" root.pub || result=$?
    if [[ -e "$FIXTURE_SENTINEL" ]]; then
      echo 'FAIL unready candidate changed stable'
      return 42
    fi
    test "$result" = 13
  }
  test_guard
  echo 'promotion check kept stable unchanged when candidate readiness failed'
  sed -i '/^kubectl .* rollout status deployment\/frontend-canary /d' ops/promote.sh
  result=0
  test_guard || result=$?
  test "$result" = 42
  echo 'negative control: caught a promotion script that bypassed readiness'
)

if command -v promtool >/dev/null || [[ "${SWITCHYARD_DELIVERY_PROMTOOL:-0}" == 1 ]]; then
  bash ops/check-alerts.sh
fi
