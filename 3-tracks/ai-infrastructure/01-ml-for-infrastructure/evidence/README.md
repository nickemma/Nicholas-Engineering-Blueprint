# ML for infrastructure · Evidence

The reference ran on Linux x86-64 with CPython 3.14.7, PyTorch 2.15.0+cpu, PyArrow 26.0.0, and SafeTensors 0.8.0. The event seed is 1729 and the model seed is 37. The [clean replay](replay.txt) starts with the lock and builds every file from the lessons. The [gate capture](gate.txt) includes the real loopback endpoint.

| Measurement | Reference |
|---|---:|
| Training, validation, holdout rows | 640 / 256 / 384 |
| Median baseline holdout MAE | 175.07 ms |
| Size baseline holdout MAE | 67.42 ms |
| PyTorch holdout MAE | 8.30 ms |
| PyTorch holdout MAE by pool | 7.75 ms fast / 8.77 ms slow |
| FIFO mean wait in the ready-cohort simulation | 6,751.3 ms |
| Predicted-first mean wait in the same simulation | 4,852.4 ms |

The weaker challenger failed the promotion check and kept the original active alias. The shifted feature window raised the input alert. Rollback restored the original prediction, and the artifact check refused modified weights. The data and waits come from a synthetic workload. The scheduling result applies to the ready-cohort assumptions in the lab.

~~~bash
SWITCHYARD_ML_LIVE=1 python3 scripts/replay_lessons.py 3-tracks/ai-infrastructure/01-ml-for-infrastructure
~~~
