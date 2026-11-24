# Messaging and resilience · Exercises

## Compare command and event identity

Start a lab worker using the [manual setup](gate/README.md#inspect-deliveries-manually). Send the same version-1 command twice, then send the version-2 equivalent with the same command ID. Compare the effect count with the number and IDs of completion events. Explain how a downstream consumer could use the completion ID to apply its own effect once.

Then keep the command ID, change the job, and send it again. Check that the dead-letter queue holds the conflicting input and explain why retrying it would be futile.

## Compare retry failures

Start the worker with `-refuse-job` set to a job in your fixture. Send that command and an unsupported version. Compare their paths to the dead-letter queue using the worker log and the drained bodies. Use the [live gate](gate/README.md) to reproduce the failure at the commit boundary and explain why checking the PostgreSQL row alone would miss the earlier acknowledgment.

## Move the crash boundary

In a disposable copy of the worker, move the process exit from immediately after commit to immediately after a confirmed completion publish and before acknowledgment. Start a replacement against the same queues and database. Record the durable effect count and the count of completion events by event ID. Explain which boundary would need coordination to prevent the duplicate event.

## Additional practice

[hookshot, a webhook delivery service](exercise-hookshot.md)
