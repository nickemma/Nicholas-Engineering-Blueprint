#!/usr/bin/env bash
set -euo pipefail
cd "${1:-.}"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
# Tests mock AWS. The local provider executable still supplies its schema.
export TF_IN_AUTOMATION=1 CHECKPOINT_DISABLE=1
terraform -chdir=infra fmt -check -recursive
init=(-backend=false -input=false -lockfile=readonly -no-color)
if [[ -n "${SWITCHYARD_AWS_PLUGIN_DIR:-}" ]]; then
  init+=("-plugin-dir=$SWITCHYARD_AWS_PLUGIN_DIR")
fi
terraform -chdir=infra init "${init[@]}" >/dev/null
terraform -chdir=infra validate -no-color
terraform -chdir=infra test -no-color
(cd queue && go vet ./... && go test -race -count=1 -v ./...)

mkdir "$work/negative"
cp infra/*.tf infra/.terraform.lock.hcl "$work/negative/"
cp -R infra/tests "$work/negative/"
python3 - "$work/negative/network.tf" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
before = 'referenced_security_group_id = aws_security_group.api.id'
start = s.index('resource "aws_vpc_security_group_ingress_rule" "db_from_api"')
end = s.index('\n}', start)
section = s[start:end]
assert section.count(before) == 1
p.write_text(s[:start] + section.replace(before, 'cidr_ipv4 = "0.0.0.0/0"') + s[end:])
PY
terraform -chdir="$work/negative" init -backend=false -input=false -lockfile=readonly \
  -no-color "-plugin-dir=$PWD/infra/.terraform/providers" >/dev/null
if terraform -chdir="$work/negative" test -no-color > "$work/negative.txt" 2>&1; then
  echo "public database mutation passed the gate" >&2
  exit 1
fi
grep -q 'Error: Test assertion failed' "$work/negative.txt"
grep -m1 'DATABASE_INGRESS:' "$work/negative.txt"
echo "negative control: rejected the widened PostgreSQL ingress"
