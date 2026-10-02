package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealth(t *testing.T) {
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

func TestHealthRejectsNonGET(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/health", nil)
	response := httptest.NewRecorder()

	health(response, request)

	if response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusMethodNotAllowed)
	}
}

func TestGreetingAtRoot(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	response := httptest.NewRecorder()

	greet(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if body := response.Body.String(); body != "Hello from the request service!\n" {
		t.Fatalf("body = %q, want greeting", body)
	}
}

func TestGreetingRejectsUnknownPath(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/unknown", nil)
	response := httptest.NewRecorder()

	greet(response, request)

	if response.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusNotFound)
	}
}

func TestGreetNameReturnsGreeting(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/greet?name=Ada", nil)
	response := httptest.NewRecorder()

	greetName(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if body := response.Body.String(); body != "Hello, Ada!\n" {
		t.Fatalf("body = %q, want greeting", body)
	}
}

func TestGreetNameRejectsMissingName(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/greet", nil)
	response := httptest.NewRecorder()

	greetName(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusBadRequest)
	}
}

func TestGreetNameRejectsOverlongName(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/greet?name=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRST", nil)
	response := httptest.NewRecorder()

	greetName(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusBadRequest)
	}
}
