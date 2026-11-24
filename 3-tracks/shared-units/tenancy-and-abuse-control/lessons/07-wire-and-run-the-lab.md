# 07 Wire and run the lab

> Tenancy and abuse control · Week 3

## The problem

The issuer, policy, database, and quota matter only when the normal HTTP routes use all of them.

## The mental model

~~~text
fixture client → /token → access token
fixture client → /jobs  → verifier and policy → quota → PostgreSQL runtime role
~~~

## Build it

### Wire the issuer and jobs API for loopback

Read a local credentials file and use generated keys. Choose local or Redis quota through configuration. Initialize the verifier from the trusted issuer component in this single-process CLI.

Create `cmd/tenant-lab/main.go`.

<!-- file: cmd/tenant-lab/main.go -->
~~~go
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"switchyard/tenantlab/internal/api"
	"switchyard/tenantlab/internal/identity"
	"switchyard/tenantlab/internal/jobs"
	"switchyard/tenantlab/internal/quota"
)

func credentials(path string) (map[string]identity.Credential, []string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, 65537))
	if err != nil {
		return nil, nil, err
	}
	var provisioned map[string]struct{ Secret, Tenant, Role string }
	if len(raw) > 65536 || json.Unmarshal(raw, &provisioned) != nil || len(provisioned) == 0 {
		return nil, nil, errors.New("invalid credential file")
	}
	clients := make(map[string]identity.Credential, len(provisioned))
	tenants := make([]string, 0, len(provisioned))
	for id, client := range provisioned {
		principal := identity.Principal{Subject: id, Tenant: client.Tenant, Role: client.Role}
		if !principal.Valid() || len(client.Secret) < 32 || len(client.Secret) > 256 {
			return nil, nil, errors.New("invalid client principal or secret")
		}
		clients[id] = identity.Credential{Secret: sha256.Sum256([]byte(client.Secret)), Principal: principal}
		tenants = append(tenants, client.Tenant)
	}
	return clients, tenants, nil
}

func run(ctx context.Context) error {
	clients, tenants, err := credentials(os.Getenv("TENANT_CREDENTIALS_FILE"))
	if err != nil {
		return err
	}
	const issuerName, audience = "switchyard-lab", "tenant-jobs"
	issuer := identity.NewIssuer(issuerName, audience)
	if err := issuer.Stage("startup"); err != nil {
		return err
	}
	if err := issuer.Activate("startup"); err != nil {
		return err
	}
	keys, err := issuer.JWKS()
	if err != nil {
		return err
	}
	verifier := identity.NewVerifier(issuerName, audience)
	if err := verifier.ReplaceJWKS(keys); err != nil {
		return err
	}

	dsn := os.Getenv("TENANT_DB_URL")
	if dsn == "" {
		return errors.New("TENANT_DB_URL is required")
	}
	db, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return err
	}
	defer db.Close()
	startup, cancel := context.WithTimeout(ctx, 3*time.Second)
	err = db.Ping(startup)
	cancel()
	if err != nil {
		return err
	}

	var limiter quota.Limiter
	switch os.Getenv("TENANT_QUOTA_MODE") {
	case "", "local":
		limiter = quota.NewLocal(tenants, 5, time.Second, time.Now)
	case "redis":
		client, err := quota.OpenRedis(os.Getenv("TENANT_REDIS_URL"))
		if err != nil {
			return err
		}
		defer client.Close()
		limiter = quota.Shared{Client: client, Prefix: "switchyard:tenant-quota:v1:", Burst: 5, Interval: time.Second}
	default:
		return errors.New("choose local or redis quota mode")
	}

	addr := os.Getenv("TENANT_LAB_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil || host != "127.0.0.1" {
		return errors.New("TENANT_LAB_ADDR must bind to 127.0.0.1")
	}
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	jobRoutes := api.Server{Verify: verifier, Store: jobs.Store{Pool: db}, Quota: limiter, Now: time.Now}.Routes()
	mux.Handle("/jobs", jobRoutes)
	mux.Handle("/jobs/", jobRoutes)
	mux.Handle("/", issuer.Routes(clients, time.Now))
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 3 * time.Second,
		WriteTimeout: 4 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 8192}
	log.Printf("tenant lab listening on %s", listener.Addr())
	stopped := make(chan error, 1)
	go func() { stopped <- server.Serve(listener) }()
	select {
	case err := <-stopped:
		return err
	case <-ctx.Done():
		shutdown, stop := context.WithTimeout(context.Background(), 3*time.Second)
		defer stop()
		return server.Shutdown(shutdown)
	}
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx); err != nil {
		log.Fatal(err)
	}
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


See [Try the API manually](../gate/README.md#try-the-api-manually) for the disposable database bootstrap and credentials format. For two API instances in the gate, each takes the same independently configured issuer snapshot. The local CLI uses a fresh key per launch.
