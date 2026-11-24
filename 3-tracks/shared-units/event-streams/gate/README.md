# Event streams gate

From the repository root, replay all lessons and run the live gate.

~~~bash
SWITCHYARD_STREAMS_LIVE=1 python3 scripts/replay_lessons.py 3-tracks/shared-units/event-streams
~~~

From your completed learner directory, check the code you wrote.

~~~bash
SWITCHYARD_STREAMS_LIVE=1 bash "$blueprint/3-tracks/shared-units/event-streams/gate/run.sh" "$PWD"
~~~

The live gate starts the `apache/kafka:4.1.0` and `postgres:17` Docker images. Each run uses fresh containers and loopback ports. The gate removes its containers and their anonymous volumes on exit. Leaving out `SWITCHYARD_STREAMS_LIVE=1` runs formatting, vet, and race-enabled unit checks.

The gate requires all five outcomes.

1. Forcing the outbox insert to fail leaves no committed history or pending row.
2. A process stops after publishing, leaving the outbox row pending. A new process publishes it again at the next offset in the same partition.
3. A projector stops after committing its database transaction. A new process in the same group reads the uncommitted offset again and sees the second copy at its separate offset. Neither delivery increments the count.
4. After committing those offsets, the original group proceeds to the new records. A fresh group and projection read all four records and rebuild the same count.
5. Running the projector variant against the same log gives the specific duplicate count, with job-a at three instead of two.

See the [reference transcripts](../evidence/README.md).

## Inspect a stream manually

Use a disposable PostgreSQL database and a local Kafka broker with a host-reachable advertised listener. Set `STREAMS_DATABASE_URL` to the PostgreSQL connection string, `STREAMS_KAFKA_BROKERS` to a comma-separated list of broker addresses, and `STREAMS_TOPIC` to a new topic name for your run. From the learner directory, run the application in separate commands.

~~~bash
go build -o streams ./cmd/streams
./streams init
./streams record -id event-1 -job job-a
./streams pending
./streams relay
./streams project -group live
./streams snapshot -group live
./streams project -group rebuild
./streams snapshot -group rebuild
~~~

Use `relay -crash` instead of the first `relay` to test a republish manually. When the crash exits, run `relay` again. Use `project -limit 2` for each fresh group after that republish. The limit is a count of fetched Kafka records.
