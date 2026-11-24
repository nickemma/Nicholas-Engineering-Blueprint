// Package idempotency lets clients retry unsafe requests safely. A request
// that repeats an Idempotency-Key gets the original response back instead
// of doing the work a second time.
package idempotency

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

const (
	HeaderKey      = "Idempotency-Key"
	HeaderReplayed = "Idempotent-Replayed"
	maxKeyLength   = 255
)

var (
	ErrInProgress = errors.New("a request with this Idempotency-Key is still in progress")
	ErrMismatch   = errors.New("Idempotency-Key was already used for a different request")
)

// Response is what the server answered the first time.
type Response struct {
	Status int
	Header http.Header
	Body   []byte
}

type record struct {
	fingerprint [32]byte
	done        bool
	response    Response
	expires     time.Time
}

// Store remembers keys and their responses in memory until they expire.
type Store struct {
	ttl time.Duration
	now func() time.Time

	mu      sync.Mutex
	records map[string]*record
}

func NewStore(ttl time.Duration, now func() time.Time) *Store {
	return &Store{ttl: ttl, now: now, records: make(map[string]*record)}
}

// Begin claims key for a request with the given fingerprint. It returns the
// stored response if the same request already finished, ErrInProgress if it
// hasn't finished yet, ErrMismatch if the key belongs to a different
// request, or nil and nil if this request may go ahead.
func (s *Store) Begin(key string, fingerprint [32]byte) (*Response, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	r, ok := s.records[key]
	if ok && s.now().After(r.expires) {
		delete(s.records, key)
		ok = false
	}
	if !ok {
		s.records[key] = &record{fingerprint: fingerprint, expires: s.now().Add(s.ttl)}
		return nil, nil
	}
	if !r.done {
		return nil, ErrInProgress
	}
	response := r.response
	return &response, nil
}

// Complete stores the final response for key.
func (s *Store) Complete(key string, response Response) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r, ok := s.records[key]; ok {
		r.done = true
		r.response = response
	}
}

// Release forgets key, so the client may retry the request for real.
func (s *Store) Release(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.records, key)
}

// Sweep removes expired keys and reports how many it removed. Run it on a
// timer so memory doesn't grow without limit.
func (s *Store) Sweep() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	removed := 0
	for key, r := range s.records {
		if s.now().After(r.expires) {
			delete(s.records, key)
			removed++
		}
	}
	return removed
}

// Len is how many keys are remembered.
func (s *Store) Len() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.records)
}

// Middleware makes next idempotent for requests that carry an
// Idempotency-Key. Requests without one pass straight through.
func Middleware(store *Store, maxBodyBytes int64, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := r.Header.Get(HeaderKey)
		if key == "" {
			next.ServeHTTP(w, r)
			return
		}
		if len(key) > maxKeyLength {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("%s must be at most %d characters", HeaderKey, maxKeyLength))
			return
		}

		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
		if err != nil {
			writeError(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("request body must not exceed %d bytes", maxBodyBytes))
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))

		cached, err := store.Begin(key, fingerprint(r, body))
		switch {
		case errors.Is(err, ErrMismatch):
			writeError(w, http.StatusUnprocessableEntity, err.Error())
		case errors.Is(err, ErrInProgress):
			w.Header().Set("Retry-After", "1")
			writeError(w, http.StatusConflict, err.Error())
		case cached != nil:
			for name, values := range cached.Header {
				w.Header()[name] = values
			}
			w.Header().Set(HeaderReplayed, "true")
			w.WriteHeader(cached.Status)
			_, _ = w.Write(cached.Body)
		default:
			recorder := &responseRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(recorder, r)
			if recorder.status >= 500 {
				store.Release(key) // not a final answer: let the client retry
				return
			}
			store.Complete(key, Response{
				Status: recorder.status,
				Header: w.Header().Clone(),
				Body:   recorder.body.Bytes(),
			})
		}
	})
}

func fingerprint(r *http.Request, body []byte) [32]byte {
	h := sha256.New()
	fmt.Fprintf(h, "%s %s\n", r.Method, r.URL.Path)
	h.Write(body)
	var sum [32]byte
	copy(sum[:], h.Sum(nil))
	return sum
}

// responseRecorder passes a response through while keeping a copy of it.
type responseRecorder struct {
	http.ResponseWriter
	status int
	body   bytes.Buffer
}

func (r *responseRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *responseRecorder) Write(b []byte) (int, error) {
	r.body.Write(b)
	return r.ResponseWriter.Write(b)
}

func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}
