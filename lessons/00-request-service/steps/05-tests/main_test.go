package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestHealthReturnsOK(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/health", nil)
	response := httptest.NewRecorder()

	health(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if body := response.Body.String(); body != "{\"status\":\"ok\"}\n" {
		t.Fatalf("body = %q, want health JSON", body)
	}
}

func TestHealthSetsJSONContentType(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/health", nil)
	response := httptest.NewRecorder()

	health(response, request)

	if got := response.Header().Get("Content-Type"); got != "application/json" {
		t.Fatalf("Content-Type = %q, want %q", got, "application/json")
	}
}

func TestHealthRejectsPost(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/health", nil)
	response := httptest.NewRecorder()

	health(response, request)

	if response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusMethodNotAllowed)
	}
	if got := response.Header().Get("Allow"); got != http.MethodGet {
		t.Fatalf("Allow = %q, want %q", got, http.MethodGet)
	}
}

func TestRoutes(t *testing.T) {
	fortyAccents := url.QueryEscape(strings.Repeat("é", 40))

	tests := []struct {
		name       string
		method     string
		target     string
		wantStatus int
		wantBody   string
	}{
		{"root greeting", http.MethodGet, "/", http.StatusOK, "Hello from the request service!"},
		{"root rejects POST", http.MethodPost, "/", http.StatusMethodNotAllowed, "method not allowed"},
		{"unknown path", http.MethodGet, "/unknown", http.StatusNotFound, "404 page not found"},
		{"health", http.MethodGet, "/health", http.StatusOK, `{"status":"ok"}`},
		{"health rejects POST", http.MethodPost, "/health", http.StatusMethodNotAllowed, "method not allowed"},
		{"greet with name", http.MethodGet, "/greet?name=Ada", http.StatusOK, "Hello, Ada!"},
		{"greet trims spaces", http.MethodGet, "/greet?name=%20Ada%20", http.StatusOK, "Hello, Ada!"},
		{"greet missing name", http.MethodGet, "/greet", http.StatusBadRequest, "name must be between 1 and 40 characters"},
		{"greet blank name", http.MethodGet, "/greet?name=%20%20", http.StatusBadRequest, "name must be between 1 and 40 characters"},
		{"greet accepts 40 characters", http.MethodGet, "/greet?name=" + strings.Repeat("a", 40), http.StatusOK, "Hello, "},
		{"greet rejects 41 characters", http.MethodGet, "/greet?name=" + strings.Repeat("a", 41), http.StatusBadRequest, "name must be between 1 and 40 characters"},
		{"greet counts characters, not bytes", http.MethodGet, "/greet?name=" + fortyAccents, http.StatusOK, "Hello, "},
		{"greet rejects POST", http.MethodPost, "/greet?name=Ada", http.StatusMethodNotAllowed, "method not allowed"},
	}

	mux := newMux()
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			request := httptest.NewRequest(tt.method, tt.target, nil)
			response := httptest.NewRecorder()

			mux.ServeHTTP(response, request)

			if response.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d", response.Code, tt.wantStatus)
			}
			if body := response.Body.String(); !strings.Contains(body, tt.wantBody) {
				t.Fatalf("body = %q, want it to contain %q", body, tt.wantBody)
			}
		})
	}
}

func TestServerOverRealConnection(t *testing.T) {
	server := httptest.NewServer(newMux())
	defer server.Close()

	response, err := http.Get(server.URL + "/health")
	if err != nil {
		t.Fatalf("GET /health: %v", err)
	}
	defer response.Body.Close()

	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusOK)
	}
	if string(body) != "{\"status\":\"ok\"}\n" {
		t.Fatalf("body = %q, want health JSON", body)
	}
}
