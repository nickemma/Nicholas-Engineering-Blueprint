package main

import (
	"testing"
	"time"
)

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestLoadConfig(t *testing.T) {
	cfg, err := loadConfig(env(nil))
	if err != nil || cfg.ListenAddr != "127.0.0.1:8080" || cfg.RequestTimeout != 2*time.Second {
		t.Fatalf("defaults = %+v, %v", cfg, err)
	}

	cfg, err = loadConfig(env(map[string]string{"LISTEN_ADDR": "0.0.0.0:9000", "REQUEST_TIMEOUT": "500ms"}))
	if err != nil || cfg.ListenAddr != "0.0.0.0:9000" || cfg.RequestTimeout != 500*time.Millisecond {
		t.Fatalf("overrides = %+v, %v", cfg, err)
	}

	if _, err := loadConfig(env(map[string]string{"LISTEN_ADDR": "8080"})); err == nil {
		t.Error("LISTEN_ADDR without a host:port form was accepted")
	}
	for _, bad := range []string{"soon", "-1s", "0s"} {
		if _, err := loadConfig(env(map[string]string{"REQUEST_TIMEOUT": bad})); err == nil {
			t.Errorf("REQUEST_TIMEOUT=%q was accepted", bad)
		}
	}
}
