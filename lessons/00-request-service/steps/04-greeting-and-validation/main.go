package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"unicode/utf8"
)

const listenAddress = "127.0.0.1:8080"

const maxNameLength = 40

type healthResponse struct {
	Status string `json:"status"`
}

func methodNotAllowed(w http.ResponseWriter, allowed string) {
	w.Header().Set("Allow", allowed)
	http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
}

func health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(healthResponse{Status: "ok"}); err != nil {
		log.Printf("write health response: %v", err)
	}
}

func greet(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}

	fmt.Fprintln(w, "Hello from the request service!")
}

func greetName(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}

	name := strings.TrimSpace(r.URL.Query().Get("name"))
	if name == "" || utf8.RuneCountInString(name) > maxNameLength {
		http.Error(w, "name must be between 1 and 40 characters", http.StatusBadRequest)
		return
	}

	fmt.Fprintf(w, "Hello, %s!\n", name)
}

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/", greet)
	mux.HandleFunc("/greet", greetName)
	mux.HandleFunc("/health", health)
	return mux
}

func main() {
	log.Printf("server listening on http://%s", listenAddress)
	if err := http.ListenAndServe(listenAddress, newMux()); err != nil {
		log.Fatal(err)
	}
}
