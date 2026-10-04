// Command api runs the KESTREL jobs service.
//
// main is the composition root: the one place that builds every concrete
// dependency and wires them together. Nothing below it creates its own.
package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"kestrel/internal/httpapi"
	"kestrel/internal/jobs"
	"kestrel/internal/memstore"
)

func main() {
	if err := run(os.Getenv); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type config struct {
	ListenAddr string
}

func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{
		ListenAddr: "127.0.0.1:8080",
	}
	if v := getenv("LISTEN_ADDR"); v != "" {
		if _, _, err := net.SplitHostPort(v); err != nil {
			return config{}, fmt.Errorf("LISTEN_ADDR must look like host:port, got %q", v)
		}
		cfg.ListenAddr = v
	}
	return cfg, nil
}

// run builds the service from its configuration and serves it. Taking the
// environment as a parameter instead of calling os.Getenv inside is what
// makes it testable.
func run(getenv func(string) string) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}

	service := jobs.NewService(memstore.New())
	handler := httpapi.NewHandler(service)

	server := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("listening on http://%s", cfg.ListenAddr)
	return server.ListenAndServe()
}
