// Command api runs the KESTREL jobs service.
package main

import (
	"log"
	"net/http"

	"kestrel/internal/httpapi"
	"kestrel/internal/jobs"
	"kestrel/internal/memstore"
)

func main() {
	store := memstore.New()
	service := jobs.NewService(store)
	handler := httpapi.NewHandler(service)

	log.Println("listening on http://127.0.0.1:8080")
	log.Fatal(http.ListenAndServe("127.0.0.1:8080", handler))
}
