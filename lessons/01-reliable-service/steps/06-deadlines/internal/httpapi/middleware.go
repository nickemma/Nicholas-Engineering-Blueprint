package httpapi

import (
	"context"
	"net/http"
	"time"
)

// withTimeout gives every request a deadline. Handlers pass r.Context() down,
// so the work below them stops when the deadline passes.
func withTimeout(d time.Duration, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), d)
		defer cancel()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
