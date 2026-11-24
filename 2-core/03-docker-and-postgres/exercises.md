# Exercise · Reserve the last seat

Build a reservation service in a new Go repository with PostgreSQL and Compose. Start with an event that has one available seat. Expose the event's remaining capacity, a reservation endpoint, and a lookup by reservation ID.

## What the finished service does

| Request | Expected result |
|---|---|
| `GET /events/1` | HTTP 200 with the event ID and available seat count |
| `POST /events/1/reservations` with `{"name":"Ada"}` and an `Idempotency-Key` | HTTP 201, a reservation ID in the JSON body, and a Location that reads it back |
| Two different reservation keys compete for the last seat | One HTTP 201 and one 409. The remaining seat count is zero |
| The winning key and payload are repeated | Same HTTP status, Location, and body, including after restarting the API |
| The winning key is reused with a different name | HTTP 422. The stored reservation stays the same |
| The event or reservation ID does not exist | HTTP 404 |

Choose a key retention window and document it. Reject empty names and malformed requests. Keep the seat update, reservation insert, and stored winning response consistent if any write fails.

## Acceptance checks

1. Start on a fresh volume. Run the migration twice and check that the second run leaves exactly one event and one seat.
2. Give ten callers ten keys and let them contend for the last seat. Query the database and prove that one reservation exists and availability is zero.
3. Repeat the same winning request after killing and restarting the API. Compare its status, Location, and response body with those from the first request.
4. Start a fresh one-seat fixture. Force a database error between reserving the seat and writing the reservation. Show that the request fails, the seat remains available, and clearing the error allows the same attempt to succeed.
5. Replace the database container while preserving the volume, then read the winning reservation and replay its key.
6. Run the tests with the race detector. Include a short README with the commands, database invariants, and the failure each check catches.
