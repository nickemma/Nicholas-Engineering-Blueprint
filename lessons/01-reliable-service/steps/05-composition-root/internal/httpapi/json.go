package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"strings"
)

const maxBodyBytes = 1 << 10 // 1 KiB

// requestError is a client mistake: it carries the status and a message
// that is safe to show the caller.
type requestError struct {
	status  int
	message string
}

func (e *requestError) Error() string { return e.message }

// decodeJSON reads exactly one JSON object into dst, refusing anything else:
// the wrong content type, an oversized body, unknown fields, or trailing data.
func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	mediaType, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if mediaType != "application/json" {
		return &requestError{http.StatusUnsupportedMediaType, "Content-Type must be application/json"}
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(dst); err != nil {
		return describeDecodeError(err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return &requestError{http.StatusBadRequest, "request body must contain a single JSON object"}
	}
	return nil
}

func describeDecodeError(err error) error {
	var syntaxErr *json.SyntaxError
	var typeErr *json.UnmarshalTypeError
	var tooLarge *http.MaxBytesError

	switch {
	case errors.Is(err, io.EOF):
		return &requestError{http.StatusBadRequest, "request body is empty"}
	case errors.As(err, &syntaxErr), errors.Is(err, io.ErrUnexpectedEOF):
		return &requestError{http.StatusBadRequest, "request body is not valid JSON"}
	case errors.As(err, &typeErr):
		return &requestError{http.StatusBadRequest, fmt.Sprintf("field %q has the wrong type", typeErr.Field)}
	case strings.HasPrefix(err.Error(), "json: unknown field "):
		field := strings.TrimPrefix(err.Error(), "json: unknown field ")
		return &requestError{http.StatusBadRequest, "unknown field " + field}
	case errors.As(err, &tooLarge):
		return &requestError{http.StatusRequestEntityTooLarge, fmt.Sprintf("request body must not exceed %d bytes", maxBodyBytes)}
	default:
		return &requestError{http.StatusBadRequest, "request body could not be read"}
	}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Warn("write response", "error", err)
	}
}

type errorResponse struct {
	Error string `json:"error"`
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, errorResponse{Error: message})
}
