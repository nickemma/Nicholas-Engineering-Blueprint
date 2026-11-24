# Messaging and resilience gate

From the repository root, rebuild the lessons in a new scratch directory and run the full gate.

~~~bash
SWITCHYARD_MESSAGING_LIVE=1 python3 scripts/replay_lessons.py 3-tracks/shared-units/messaging-and-resilience
~~~

From your completed learner directory, use the gate directly.

~~~bash
SWITCHYARD_MESSAGING_LIVE=1 bash "$blueprint/3-tracks/shared-units/messaging-and-resilience/gate/run.sh" "$PWD"
~~~

Both commands need Go, Bash, Python 3, and a running Docker daemon. The live gate starts RabbitMQ and PostgreSQL with unique container names and disposable storage. It publishes each service on a dynamically assigned loopback port and removes its containers after each run. Leaving out `SWITCHYARD_MESSAGING_LIVE=1` runs the format, vet, and race-enabled Go checks.

The live reference case must report a committed effect before the process exits, a redelivery and completion after restart, one effect across two schema versions, and dead letters for permanent and exhausted temporary failures. The negative build must hit the specific lost-redelivery assertion. A broker startup failure or a generic process error fails the gate.

See the [recorded run](../evidence/README.md).

## Inspect deliveries manually

Use a fresh RabbitMQ vhost and PostgreSQL database dedicated to this exercise. Set `MESSAGING_AMQP_URL` and `MESSAGING_DATABASE_URL` for those instances in both shells. Build the CLI once from the learner directory and start a worker in the first shell.

~~~bash
go build -o messages ./cmd/messages
./messages work
~~~

In the second shell, send a command, wait for the worker to log its acknowledgment, then inspect its event and durable effect.

~~~bash
cat > command.json <<'JSON'
{"id":"practice-1","kind":"record-job","version":1,"payload":{"job_id":"job-1"}}
JSON
./messages send -input command.json
./messages drain -queue switchyard.events
./messages count
~~~

A version-2 command uses `"version":2` and `"payload":{"job":"job-1"}`. Inspect dead letters with `./messages drain -queue switchyard.dead`. The drain command acknowledges and removes the inspected messages. Stop the worker with Ctrl+C before starting a worker with different flags.
