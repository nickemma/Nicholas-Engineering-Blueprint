# 04 Scope PostgreSQL to the tenant

> Tenancy and abuse control · Week 2

## The problem

Different customers can have the same job ID. The database should apply the tenant boundary even when an application query omits its explicit tenant filter.

## The mental model

~~~text
verified tenant → checked-out PostgreSQL connection → BEGIN
    set_config(..., true) → scoped SELECT or INSERT → COMMIT → connection returns
~~~

## The pattern

Use a composite key and PostgreSQL row-level security (RLS). The owner applies the schema. The runtime role receives only schema usage and row permissions for operations it actually supports. Its transaction sets the verified tenant locally. If tenant context is absent, the policy matches no rows and rejects writes. Superusers and roles with `BYPASSRLS` bypass these policies, so use the dedicated runtime login. [PostgreSQL row security](https://www.postgresql.org/docs/17/ddl-rowsecurity.html)

The database trusts the API to set the verified tenant. The runtime login can set that variable, so protect its credential and use parameterized queries on the request path.

## Build it

### Install the table, policy, and grants

Use USING for row visibility and WITH CHECK for rows written through the runtime role. The gate creates the role separately from the owner.

Create `db/schema.sql`.

<!-- file: db/schema.sql -->
~~~sql
CREATE SCHEMA tenant_lab;
CREATE TABLE tenant_lab.jobs (
    tenant text NOT NULL,
    id text NOT NULL,
    name text NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
    PRIMARY KEY (tenant, id)
);

ALTER TABLE tenant_lab.jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_lab.jobs FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON tenant_lab.jobs TO tenant_api
    USING (tenant = nullif(current_setting('switchyard.tenant', true), ''))
    WITH CHECK (tenant = nullif(current_setting('switchyard.tenant', true), ''));

GRANT USAGE ON SCHEMA tenant_lab TO tenant_api;
GRANT SELECT, INSERT ON tenant_lab.jobs TO tenant_api;
~~~

### Set tenant context inside each transaction

Keep an application filter and the RLS check. Parameterize the tenant taken from the authenticated principal.

Create `internal/jobs/store.go`.

<!-- file: internal/jobs/store.go -->
~~~go
package jobs

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Job struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type Store struct{ Pool *pgxpool.Pool }

func (s Store) begin(ctx context.Context, tenant string) (pgx.Tx, error) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, "SELECT set_config('switchyard.tenant', $1, true)", tenant); err != nil {
		_ = tx.Rollback(ctx)
		return nil, err
	}
	return tx, nil
}

func (s Store) Get(ctx context.Context, tenant, id string) (Job, error) {
	tx, err := s.begin(ctx, tenant)
	if err != nil {
		return Job{}, err
	}
	defer tx.Rollback(ctx)

	// Keep both the lookup and the database policy explicitly scoped.
	var result Job
	err = tx.QueryRow(ctx, "SELECT id, name FROM tenant_lab.jobs WHERE tenant = $1 AND id = $2",
		tenant, id).Scan(&result.ID, &result.Name)
	if err != nil {
		return Job{}, err
	}
	return result, tx.Commit(ctx)
}

func (s Store) Create(ctx context.Context, tenant string, job Job) error {
	tx, err := s.begin(ctx, tenant)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, "INSERT INTO tenant_lab.jobs (tenant, id, name) VALUES ($1, $2, $3)",
		tenant, job.ID, job.Name); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


The live database test uses one pooled connection and alternates scoped and unscoped transactions. It checks that neither tenant context survives its transaction. Read the [gate setup](../gate/README.md) for the separation of owner and runtime roles.
