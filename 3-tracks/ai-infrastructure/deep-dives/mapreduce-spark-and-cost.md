# MapReduce, Spark and the single-machine baseline

Use the synthetic event format from [ML for infrastructure](../01-ml-for-infrastructure/README.md). Group completed jobs by tenant and calculate count and total duration. Map each row to a tenant and a partial aggregate, combine partitions, and reduce by tenant. The reducer can merge counts and sums. Compute the mean after the final reduction so groups of different sizes receive the correct weight.

Create a one-process streaming implementation as the reference. Then implement the same aggregation with partition-local maps and the same operation through Spark, where available. Keep tenant IDs, seeds, input bytes, and output rows fixed. Before measuring speed, compare the complete sorted output against the reference. Include one large tenant to observe a skewed partition.

## Measure the crossover

Record cold and warm runs separately. Time startup, reading, shuffle, and aggregation. Compare the one-process baseline with several worker counts over increasing input sizes. Report elapsed time and worker-seconds. Treat startup as an operational cost when deploying one-off tasks. If you reuse a session, state how many tasks share it.

The COST question is how many workers the scalable system needs to beat a competent single-worker baseline. Plot the smallest such worker count at each input size you tested. If the crossover never occurs, retain that outcome. Explain whether the next experiment should change file size, placement, or the aggregation.

## Runnable check

Check the merge law on a skewed synthetic fixture before measuring Spark. This check validates local output equivalence.

<!-- file: aggregate.py -->
~~~python
from collections import defaultdict


def aggregate(rows):
    totals = defaultdict(lambda: (0, 0))
    for tenant, duration in rows:
        count, total = totals[tenant]
        totals[tenant] = count + 1, total + duration
    return totals


def merge(partials):
    totals = defaultdict(lambda: (0, 0))
    for partial in partials:
        for tenant, (count, duration) in partial.items():
            prior_count, prior_duration = totals[tenant]
            totals[tenant] = prior_count + count, prior_duration + duration
    return totals


rows = [("busy" if i % 7 else "small", i % 61) for i in range(10001)]
partitions = [rows[i::8] for i in range(8)]
assert merge(aggregate(part) for part in partitions) == aggregate(rows)
assert merge([{}, { "busy": (2, 12) }, { "busy": (1, 3) }])["busy"] == (3, 15)
~~~

<!-- run: python3 aggregate.py -->

Compare your observations with the [historical crossover capture](evidence/README.md). Keep the runs separate when fixture sizes or machine resources differ.

## Check the Spark result locally

The local Spark check transfers the same deterministic tenant and duration fixture to the Spark driver. It verifies that both worker settings produce the streaming baseline's complete result. The printed times include the one-shot startup and cleanup in this process. A repeat within a long-lived Spark session answers a different question.

<!-- file: compare_spark.py -->
~~~python
from time import perf_counter

from pyspark.sql import SparkSession, functions as sql

from aggregate import aggregate, rows


start = perf_counter()
expected = aggregate(rows)
print(f"streaming baseline: {perf_counter() - start:.3f}s")
for workers in (1, 2):
    start = perf_counter()
    with (
        SparkSession.builder.master(f"local[{workers}]")
        .appName("switchyard-aggregation")
        .config("spark.ui.enabled", "false")
        .config("spark.sql.shuffle.partitions", str(workers))
        .getOrCreate()
    ) as spark:
        result = spark.createDataFrame(rows, ["tenant", "duration"]).groupBy("tenant").agg(
            sql.count("*").alias("count"),
            sql.sum("duration").alias("total"),
        )
        actual = {row["tenant"]: (row["count"], row["total"]) for row in result.collect()}
        assert actual == expected
    print(f"Spark with {workers} workers: {perf_counter() - start:.3f}s, same result")
~~~

Run with Java and local loopback sockets available.

~~~bash
SPARK_LOCAL_IP=127.0.0.1 uv run --no-project --python 3.12 --with pyspark==4.2.0 python compare_spark.py
~~~
