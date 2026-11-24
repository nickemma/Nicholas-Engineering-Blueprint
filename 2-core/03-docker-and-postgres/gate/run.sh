#!/usr/bin/env bash
set -euo pipefail

gate=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "${1:-.}"
project="c03-gate-$(id -u)-$$"
work=$(mktemp -d)
compose() { docker compose -p "$project" "$@"; }
cleanup() {
  local rc=$?
  if ((rc != 0)); then
    compose logs postgres migrate api worker >&2 || true
  fi
  compose down -v --remove-orphans >&2 || true
  rm -rf "$work"
}
trap cleanup EXIT

unset SWITCHYARD_DATABASE_URL
export SWITCHYARD_LEASE_TTL=2m QUEUE_CAPACITY=100

test -z "$(gofmt -l .)"
go vet ./...
bash scripts/build-image-inputs.sh
compose build api
compose up -d --wait postgres

compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U switchyard -d switchyard \
  -c 'CREATE DATABASE switchyard_contract'
postgres_port=$(compose port postgres 5432)
export SWITCHYARD_TEST_DATABASE_URL="postgres://switchyard:lab-only@$postgres_port/switchyard_contract?sslmode=disable"
psql "$SWITCHYARD_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f db/migrate.sql
go test -race -count=1 ./...
printf 'repository contracts, exhausted pool, transactional rollback, and recovery checks passed\n'

go build -buildvcs=false -o "$work/leaseprobe" ./cmd/leaseprobe
compose up -d api
python3 "$gate/verify.py" "$project" "$work/leaseprobe"
