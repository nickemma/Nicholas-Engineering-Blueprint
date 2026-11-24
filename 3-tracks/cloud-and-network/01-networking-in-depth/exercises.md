# Networking in depth · Exercises

Use the same report format for each exercise. Record the topology, offered work, configuration, observations, and evidence for your conclusion.

## Fix the queue

Keep the same nominal delay and shaping rate. Compare a deep FIFO and FQ-CoDel over at least five shuffled runs per queue.

- Calibrate idle RTT and receiver goodput and verify the expected interface counters before testing the change.
- Keep each run’s loaded RTT, drops, and goodput. Report the median and spread.
- Run two competing flows, using BBR and CUBIC if available. Compare their shares across the two queue policies and explain what your sample covers.

## Measure a real path you control

Choose two hosts you control. Measure idle RTT, loaded RTT, and throughput over at least five runs at two times of day.

- Estimate BDP and compare it with the socket state observed through `ss -ti`.
- If both are available, run CUBIC and BBR with the same traffic settings. Record congestion and window evidence before choosing a diagnosis.
- Write down one link characteristic the namespace fixture did not reproduce.

## Exercise a Switchyard dependency

Use your disposable Switchyard deployment and impair the link from its API to the worker. Compare a healthy run with 40 ms of delay and 1% loss.

- Record end-to-end p99 and worker-side outcomes for equivalent offered loads.
- Change one input such as connection reuse or the timeout. Repeat both conditions with the matched load.
- Document what a caller can infer from a timeout and show the recovery trace after removing the impairment.

Compare with the [gate and evidence](gate/README.md).
