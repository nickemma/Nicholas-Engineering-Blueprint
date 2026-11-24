# Rust inference gateway · Exercises

## Gateway for streamed transcripts

Build a separate HTTP gateway for a fixture that streams timed transcript segments. Give each tenant a weighted budget based on requested audio seconds. Use a maximum segment size and a separate connection lifetime.

### Acceptance

- Frame a split UTF-8 segment and multiline data across arbitrary response chunks. Validate the semantic event before forwarding it.
- Hold one transcript open. Show a concurrent request hits the admission limit. Drop the first client and verify closure at the model-facing connection, then admit a new request.
- Show that dropping a billed transcript leaves the original reservation charged. Exhaust that tenant's tokens and verify another tenant succeeds.
- Test a timeout and a stream that ends before final metadata. Record their terminal outcomes alongside a complete transcript.
- Replace the multiline join in a temporary build and show that the same parser test catches the changed data.

## Compare first transport data and first content

Have the fixture send a heartbeat and a metadata event before the first segment. Hold the segment until you can observe the metrics. Explain which timestamp a latency report needs and how you would measure it without reading ahead of the client.

## Rust as a service

Follow [Build a Rust job-status service](../deep-dives/rust-as-a-service.md) for the code and the client and Compose checks. Then use this checklist to build your own variant.

1. Expose `POST /jobs` and `GET /jobs/{id}` with a Rust HTTP framework. Separate routing, domain logic and storage. Use typed request and response data, bound request size, and map invalid input, missing jobs and storage outages to distinct responses. Persist a job through a process restart with a PostgreSQL adapter and use an in-memory adapter for unit tests.
2. Generate OpenAPI from the REST routes and schemas. In CI, check that the document lists the implemented operations, error responses and required fields. Change one request field in a disposable branch and show that the contract check catches the mismatch. [Rust OpenAPI generation](https://docs.rs/utoipa/latest/utoipa/trait.OpenApi.html)
3. Give each request a trace span and propagate its context to the storage call or a downstream fixture. Use the same image with local and test configuration supplied at startup. Verify that invalid configuration fails before the server takes traffic and that credentials stay out of logs.
4. Expose the lookup over gRPC and add a WebSocket subscription for job-status changes. Check that both HTTP and gRPC return the same job state. Bound the subscription buffer, disconnect a slow subscriber, and verify that a closed client releases its subscription. Explain when each transport suits a caller.
5. Run the service and database with Compose. Test readiness during startup, drain an in-flight request during shutdown, and demonstrate rollback to a previous image against a compatible schema. Compare one and two service replicas at the same offered load. Record throughput, p99, failures and database pool usage so you can tell whether the service tier or the shared database limits scaling.
