# 06 Run the crash and redelivery gate

Send a version-1 command, stop the worker just after commit, then start a replacement. Observe one durable effect and a completion event after the redelivery. Send the version-2 equivalent, then send unsupported and conflicting inputs. Finish with a worker whose fixture dependency refuses one job until the broker's redelivery budget is exhausted.

The disposable negative control acknowledges the command early and crashes at the same point. It must fail because the broker already removed that delivery. The [gate guide](../gate/README.md) describes both runs. The [exercises](../exercises.md) ask you to compare command identity and event identity.

## Check it

~~~bash
SWITCHYARD_MESSAGING_LIVE=1 bash "$blueprint/3-tracks/shared-units/messaging-and-resilience/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/shared-units/messaging-and-resilience/gate/run.sh" "$PWD" -->
