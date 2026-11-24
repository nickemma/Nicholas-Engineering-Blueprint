# 01 Commands, events, and versions

A command asks the receiver to do something. An event records what happened. Use a stable command identity that can travel across retries. Keep the wire version separate so the same command can arrive with the old `job_id` field or the new `job` field.

Normalize the two versions to the same typed value before proceeding. Construct the completion event from the normalized command. It has its own stable identity, derived from the command, so a downstream event consumer can make its own idempotency decision.

### go.mod

Create `go.mod`.

<!-- file: go.mod -->
~~~text
module switchyard/messaging

go 1.26.6

require (
	github.com/jackc/pgx/v5 v5.11.0
	github.com/rabbitmq/amqp091-go v1.15.0
)

require (
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	golang.org/x/sync v0.17.0 // indirect
	golang.org/x/text v0.29.0 // indirect
)
~~~

### go.sum

Create `go.sum`.

<!-- file: go.sum -->
~~~text
github.com/davecgh/go-spew v1.1.0/go.mod h1:J7Y8YcW2NihsgmVo/mv3lAwl/skON4iLHjSsI+c5H38=
github.com/davecgh/go-spew v1.1.1 h1:vj9j/u1bqnvCEfJOwUhtlOARqs3+rkHYY13jYWTU97c=
github.com/davecgh/go-spew v1.1.1/go.mod h1:J7Y8YcW2NihsgmVo/mv3lAwl/skON4iLHjSsI+c5H38=
github.com/jackc/pgpassfile v1.0.0 h1:/6Hmqy13Ss2zCq62VdNG8tM1wchn8zjSGOBJ6icpsIM=
github.com/jackc/pgpassfile v1.0.0/go.mod h1:CEx0iS5ambNFdcRtxPj5JhEz+xB6uRky5eyVu/W2HEg=
github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 h1:iCEnooe7UlwOQYpKFhBabPMi4aNAfoODPEFNiAnClxo=
github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761/go.mod h1:5TJZWKEWniPve33vlWYSoGYefn3gLQRzjfDlhSJ9ZKM=
github.com/jackc/pgx/v5 v5.11.0 h1:IzBBtyK9AHqf98cctWFifYSci2hgQR/cd56wB4p+ogg=
github.com/jackc/pgx/v5 v5.11.0/go.mod h1:mal1tBGAFfLHvZzaYh77YS/eC6IX9OWbRV1QIIM0Jn4=
github.com/jackc/puddle/v2 v2.2.2 h1:PR8nw+E/1w0GLuRFSmiioY6UooMp6KJv0/61nB7icHo=
github.com/jackc/puddle/v2 v2.2.2/go.mod h1:vriiEXHvEE654aYKXXjOvZM39qJ0q+azkZFrfEOc3H4=
github.com/pmezard/go-difflib v1.0.0 h1:4DBwDE0NGyQoBHbLQYPwSUPoCMWR5BEzIk/f1lZbAQM=
github.com/pmezard/go-difflib v1.0.0/go.mod h1:iKH77koFhYxTK1pcRnkKkqfTogsbg7gZNVY4sRDYZ/4=
github.com/rabbitmq/amqp091-go v1.15.0 h1:LEQL4/yp48/Wigt6A6XOu18RQRo8ZHtB5I/KZJn+gkw=
github.com/rabbitmq/amqp091-go v1.15.0/go.mod h1:Hy4jKW5kQART1u+JkDTF9YYOQUHXqMuhrgxOEeS7G4o=
github.com/stretchr/objx v0.1.0/go.mod h1:HFkY916IF+rwdDfMAkV7OtwuqBVzrE8GR6GFx+wExME=
github.com/stretchr/testify v1.3.0/go.mod h1:M5WIy9Dh21IEIfnGCwXGc5bZfKNJtfHm1UVUgZn+9EI=
github.com/stretchr/testify v1.7.0/go.mod h1:6Fq8oRcR53rry900zMqJjRRixrwX3KX962/h/Wwjteg=
github.com/stretchr/testify v1.11.1 h1:7s2iGBzp5EwR7/aIZr8ao5+dra3wiQyKjjFuvgVKu7U=
github.com/stretchr/testify v1.11.1/go.mod h1:wZwfW3scLgRK+23gO65QZefKpKQRnfz6sD981Nm4B6U=
go.uber.org/goleak v1.3.0 h1:2K3zAYmnTNqV73imy9J1T3WC+gmCePx2hEGkimedGto=
go.uber.org/goleak v1.3.0/go.mod h1:CoHD4mav9JJNrW/WLlf7HGZPjdw8EucARQHekz1X6bE=
golang.org/x/sync v0.17.0 h1:l60nONMj9l5drqw6jlhIELNv9I0A4OFgRsG9k2oT9Ug=
golang.org/x/sync v0.17.0/go.mod h1:9KTHXmSnoGruLpwFjVSX0lNNA75CykiMECbovNTZqGI=
golang.org/x/text v0.29.0 h1:1neNs90w9YzJ9BocxfsQNHKuAT4pkghyXc4nhZ6sJvk=
golang.org/x/text v0.29.0/go.mod h1:7MhJOA9CD2qZyOKYazxdYMF85OwPdEr9jTtBpO7ydH4=
gopkg.in/check.v1 v0.0.0-20161208181325-20d25e280405/go.mod h1:Co6ibVJAznAaIkqp8huTwlJQCZ016jof/cbN4VW5Yz0=
gopkg.in/yaml.v3 v3.0.0-20200313102051-9f266ea9e77c/go.mod h1:K4uyk7z7BCEPqu6E+C64Yfv1cQ7kz7rIZviUmN+EgEM=
gopkg.in/yaml.v3 v3.0.1 h1:fxVm/GzAzEWqLHuvctI91KS9hhNmmWOoWu0XTYJS7CA=
gopkg.in/yaml.v3 v3.0.1/go.mod h1:K4uyk7z7BCEPqu6E+C64Yfv1cQ7kz7rIZviUmN+EgEM=
~~~

### message.go

Create `internal/contract/message.go`.

<!-- file: internal/contract/message.go -->
~~~go
// Package contract turns both supported wire versions into one command.
package contract

import (
	"encoding/json"
	"errors"
)

type Command struct{ ID, Job string }

type envelope struct {
	ID      string          `json:"id"`
	Kind    string          `json:"kind"`
	Version int             `json:"version"`
	Payload json.RawMessage `json:"payload"`
}

func Decode(raw []byte) (Command, error) {
	var e envelope
	if len(raw) > 65536 || json.Unmarshal(raw, &e) != nil || e.ID == "" || len(e.ID) > 128 || e.Kind != "record-job" {
		return Command{}, errors.New("invalid command envelope")
	}
	var job string
	switch e.Version {
	case 1:
		var p struct {
			Job string `json:"job_id"`
		}
		if err := json.Unmarshal(e.Payload, &p); err != nil {
			return Command{}, err
		}
		job = p.Job
	case 2:
		var p struct {
			Job string `json:"job"`
		}
		if err := json.Unmarshal(e.Payload, &p); err != nil {
			return Command{}, err
		}
		job = p.Job
	default:
		return Command{}, errors.New("unsupported command schema")
	}
	if job == "" || len(job) > 128 {
		return Command{}, errors.New("invalid job identity")
	}
	return Command{ID: e.ID, Job: job}, nil
}

func Recorded(command Command) []byte {
	p, _ := json.Marshal(struct {
		Job string `json:"job"`
	}{command.Job})
	raw, _ := json.Marshal(envelope{command.ID + ":recorded", "job-recorded", 1, p})
	return raw
}
~~~

### message_test.go

Create `internal/contract/message_test.go`.

<!-- file: internal/contract/message_test.go -->
~~~go
package contract

import "testing"

func TestBothVersionsNormalize(t *testing.T) {
	for _, raw := range []string{
		`{"id":"cmd","kind":"record-job","version":1,"payload":{"job_id":"job"}}`,
		`{"id":"cmd","kind":"record-job","version":2,"payload":{"job":"job"}}`,
	} {
		got, err := Decode([]byte(raw))
		if err != nil || got != (Command{"cmd", "job"}) {
			t.Fatalf("got %+v %v", got, err)
		}
	}
	if _, err := Decode([]byte(`{"id":"cmd","kind":"record-job","version":99,"payload":{"job":"job"}}`)); err == nil {
		t.Fatal("accepted unsupported version")
	}
	t.Log("two command versions normalize to the same effect")
}
~~~

## Check it

~~~bash
go test -race -count=1 -v ./internal/contract
~~~

<!-- run: go test -race -count=1 -v ./internal/contract -->
