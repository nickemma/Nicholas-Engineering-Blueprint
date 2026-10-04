package httpapi

import (
	"context"
	"log/slog"
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

// statusRecorder remembers the status a handler wrote, so middleware can
// log and count it afterwards.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(status int) {
	s.status = status
	s.ResponseWriter.WriteHeader(status)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}

// withRequestLog writes one structured record per request. It logs the
// route pattern rather than the raw path, and never logs bodies.
func withRequestLog(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(recorder, r)
		logger.Info("request",
			"method", r.Method,
			"route", routeOf(r),
			"status", recorder.status,
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}

// withRecover turns a panic in any handler into a 500 instead of a dropped
// connection, and logs it.
func withRecover(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				logger.Error("panic", "method", r.Method, "path", r.URL.Path, "panic", v)
				writeError(w, http.StatusInternalServerError, "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// routeOf returns the pattern the router matched, such as "GET /jobs/{id}".
// The router sets r.Pattern on the request it was given, so middleware that
// passed that same request can read it after calling next. Logging the
// pattern instead of the raw path keeps labels few: /jobs/1 and /jobs/2
// are one route. Unmatched requests have no pattern.
func routeOf(r *http.Request) string {
	if r.Pattern == "" {
		return "unmatched"
	}
	return r.Pattern
}
