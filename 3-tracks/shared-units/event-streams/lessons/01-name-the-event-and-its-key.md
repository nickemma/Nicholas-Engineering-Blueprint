# 01 Name the event and its partition key

> Event streams · Week 1

## The problem

A relay can publish the same event twice. A consumer needs one identity for the business event and a different coordinate for each position in the log.

## The mental model

~~~text
event ID   event-1                          same on retry
job key    job-a                            selects a partition
location   topic / partition / offset       assigned by Kafka
~~~

## The pattern

Use a versioned JSON event and use the job ID as the Kafka key. The business event ID comes from the caller and stays fixed across retries. Each Kafka partition is an ordered log with its own offsets. Keep the topic's partition count constant for the lab so a key maps consistently. [Kafka introduction](https://kafka.apache.org/41/getting-started/introduction/)

## Build it

### Pin the clients

Use pgx for PostgreSQL and franz-go for Kafka, the same clients used by the durable-data lessons.

Create `go.mod`.

<!-- file: go.mod -->
~~~go
module switchyard/streams

go 1.26.6

require (
	github.com/jackc/pgx/v5 v5.11.0
	github.com/twmb/franz-go v1.22.1
	github.com/twmb/franz-go/pkg/kadm v1.19.0
)

require (
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	github.com/klauspost/compress v1.20.0 // indirect
	github.com/pierrec/lz4/v4 v4.1.30 // indirect
	github.com/twmb/franz-go/pkg/kmsg v1.14.0 // indirect
	golang.org/x/sync v0.17.0 // indirect
	golang.org/x/text v0.29.0 // indirect
)
~~~

### Record dependency checksums

Keep the Go checksums beside the module file.

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
github.com/klauspost/compress v1.20.0 h1:a3C1ke2ohxFymNlb2HWAHjDeKCI90scRskErZkR0ezA=
github.com/klauspost/compress v1.20.0/go.mod h1:LUdAzn7YLVvxLpc7y3V1m40wESHTgc1422pwwBSKYuI=
github.com/pierrec/lz4/v4 v4.1.30 h1:cchX8N2DVP668WkElI9QMwVyoNabLkq1LofDHFeIrdg=
github.com/pierrec/lz4/v4 v4.1.30/go.mod h1:EoQMVJgeeEOMsCqCzqFm2O0cJvljX2nGZjcRIPL34O4=
github.com/pmezard/go-difflib v1.0.0 h1:4DBwDE0NGyQoBHbLQYPwSUPoCMWR5BEzIk/f1lZbAQM=
github.com/pmezard/go-difflib v1.0.0/go.mod h1:iKH77koFhYxTK1pcRnkKkqfTogsbg7gZNVY4sRDYZ/4=
github.com/stretchr/objx v0.1.0/go.mod h1:HFkY916IF+rwdDfMAkV7OtwuqBVzrE8GR6GFx+wExME=
github.com/stretchr/testify v1.3.0/go.mod h1:M5WIy9Dh21IEIfnGCwXGc5bZfKNJtfHm1UVUgZn+9EI=
github.com/stretchr/testify v1.7.0/go.mod h1:6Fq8oRcR53rry900zMqJjRRixrwX3KX962/h/Wwjteg=
github.com/stretchr/testify v1.11.1 h1:7s2iGBzp5EwR7/aIZr8ao5+dra3wiQyKjjFuvgVKu7U=
github.com/stretchr/testify v1.11.1/go.mod h1:wZwfW3scLgRK+23gO65QZefKpKQRnfz6sD981Nm4B6U=
github.com/twmb/franz-go v1.22.1 h1:J7Xixbb7k0Itl39eaBot5PIblZh9IL3ZKYgo2yzlf40=
github.com/twmb/franz-go v1.22.1/go.mod h1:b2qISbZgMTJRcIsltVqPz4+Bb2Lw/9bN+/Gd0C07kYw=
github.com/twmb/franz-go/pkg/kadm v1.19.0 h1:5Nx/WWFkpNUi8Z55Skxvn9x5HOCjw+BUntSNB1kLglk=
github.com/twmb/franz-go/pkg/kadm v1.19.0/go.mod h1:emmsx5J7YPU9A7UHcSoz0fBMYVmCcJO2etylJeU0VHU=
github.com/twmb/franz-go/pkg/kmsg v1.14.0 h1:gSxrBEKWl3qnsx3QKWol5OEVujuPmIoDkhMt3didFKM=
github.com/twmb/franz-go/pkg/kmsg v1.14.0/go.mod h1:+DPt4NC8RmI6hqb8G09+3giKObE6uD2Eya6CfqBpeJY=
golang.org/x/sync v0.17.0 h1:l60nONMj9l5drqw6jlhIELNv9I0A4OFgRsG9k2oT9Ug=
golang.org/x/sync v0.17.0/go.mod h1:9KTHXmSnoGruLpwFjVSX0lNNA75CykiMECbovNTZqGI=
golang.org/x/text v0.29.0 h1:1neNs90w9YzJ9BocxfsQNHKuAT4pkghyXc4nhZ6sJvk=
golang.org/x/text v0.29.0/go.mod h1:7MhJOA9CD2qZyOKYazxdYMF85OwPdEr9jTtBpO7ydH4=
gopkg.in/check.v1 v0.0.0-20161208181325-20d25e280405/go.mod h1:Co6ibVJAznAaIkqp8huTwlJQCZ016jof/cbN4VW5Yz0=
gopkg.in/yaml.v3 v3.0.0-20200313102051-9f266ea9e77c/go.mod h1:K4uyk7z7BCEPqu6E+C64Yfv1cQ7kz7rIZviUmN+EgEM=
gopkg.in/yaml.v3 v3.0.1 h1:fxVm/GzAzEWqLHuvctI91KS9hhNmmWOoWu0XTYJS7CA=
gopkg.in/yaml.v3 v3.0.1/go.mod h1:K4uyk7z7BCEPqu6E+C64Yfv1cQ7kz7rIZviUmN+EgEM=
~~~

### Encode the contract

Bound the event and key sizes, validate the kind and schema version, and compare the payload job with the actual record key.

Create `internal/event/event.go`.

<!-- file: internal/event/event.go -->
~~~go
// Package event defines the records stored in the outbox and published to Kafka.
package event

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
)

const recorded = "job-recorded"

var name = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$`)

type Event struct {
	ID      string `json:"id"`
	Job     string `json:"job"`
	Kind    string `json:"kind"`
	Version int    `json:"version"`
}

func New(id, job string) (Event, error) {
	e := Event{ID: id, Job: job, Kind: recorded, Version: 1}
	return e, e.validate()
}

func Decode(key, body []byte) (Event, error) {
	var e Event
	if len(body) > 4096 {
		return Event{}, errors.New("record exceeds 4096 bytes")
	}
	if err := json.Unmarshal(body, &e); err != nil {
		return Event{}, fmt.Errorf("decode record: %w", err)
	}
	if err := e.validate(); err != nil {
		return Event{}, err
	}
	if string(key) != e.Job {
		return Event{}, errors.New("partition key differs from the job in the payload")
	}
	return e, nil
}

func (e Event) validate() error {
	if e.Kind != recorded || e.Version != 1 {
		return errors.New("unsupported event kind or version")
	}
	if !ValidName(e.ID) || !ValidName(e.Job) {
		return errors.New("invalid event or job identity")
	}
	return nil
}

func ValidName(value string) bool { return name.MatchString(value) }
~~~

### Check the producer and consumer agree

Decode a valid event and then change a single property in each failing case.

Create `internal/event/event_test.go`.

<!-- file: internal/event/event_test.go -->
~~~go
package event

import (
	"encoding/json"
	"testing"
)

func TestDecodeChecksKeyAndVersion(t *testing.T) {
	e, err := New("event-1", "job-1")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	if decoded, err := Decode([]byte(e.Job), raw); err != nil || decoded != e {
		t.Fatalf("decode = %+v, %v", decoded, err)
	}
	if _, err := Decode([]byte("job-2"), raw); err == nil {
		t.Fatal("accepted the wrong partition key")
	}
	if _, err := Decode([]byte(e.Job), []byte(`{"id":"event-1","job":"job-1","kind":"job-recorded","version":2}`)); err == nil {
		t.Fatal("accepted an unsupported version")
	}
}
~~~

## Check it

~~~bash
go test -race -count=1 -v ./internal/event
~~~

<!-- run: go test -race -count=1 -v ./internal/event -->

Look for `PASS: TestDecodeChecksKeyAndVersion`. If the bad-key case passes validation, check the actual Kafka record key passed to `Decode`.
