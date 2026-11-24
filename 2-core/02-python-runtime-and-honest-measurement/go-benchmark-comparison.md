# Compare repeated Go benchmarks

Use the same idea as the [HTTP repeat-run comparison](lessons/08-repeat-runs-and-confidence-intervals.md) when measuring a Go microbenchmark. A single invocation gives a cost per operation for its selected number of iterations. Compare several independent invocations with the same benchmark name, toolchain, concurrency, and workload. Alternate or randomize baseline and candidate order to make machine drift visible. Run an A/A control before attributing a small delta to the change.

Capture complete output from `go test -run '^$' -bench 'BenchmarkName$' -benchmem -count=10`. Keep `ns/op`, `B/op`, and `allocs/op` separate. An allocation difference can explain part of a timing difference. It doesn't account for the whole service's latency. If using benchstat, give it the preserved output from both runs and compare its summary with your per-run observations.

## Check the parser

The parser retains every measurement unit from a result line. Requiring exactly one measurement prevents accidentally picking the first benchmark or silently mixing units.

<!-- file: gobench.py -->
~~~python
"""Reading `go test -bench` output."""

import re

# BenchmarkRoundTrip/relays-16    39811    28292 ns/op    512 B/op
# name, then GOMAXPROCS after the dash, then iterations, then value-unit pairs.
LINE = re.compile(r"^(Benchmark\S+?)(?:-(\d+))?\s+(\d+)\s+(.*)$")


def parse(output: str) -> list[dict[str, float | str]]:
    """Return one dict per result line: name, procs, iterations, and each unit's value."""
    results = []
    for line in output.splitlines():
        match = LINE.match(line.strip())
        if not match:
            continue
        name, procs, iterations, rest = match.groups()
        result: dict[str, float | str] = {
            "name": name,
            "procs": int(procs or 1),
            "iterations": int(iterations),
        }
        fields = rest.split()
        for value, unit in zip(fields[::2], fields[1::2], strict=False):
            result[unit] = float(value)
        results.append(result)
    return results


def value(output: str, unit: str) -> float:
    """The one value in output measured in unit. Anything else is an error, not a guess."""
    found = [r[unit] for r in parse(output) if unit in r]
    if len(found) != 1:
        raise ValueError(f"want exactly one {unit} result, found {len(found)}")
    return float(found[0])


fixture = "BenchmarkLookup-8    2000000    18.20 ns/op    16 B/op    1 allocs/op"
assert value(fixture, "ns/op") == 18.2
assert value(fixture, "B/op") == 16
try:
    value(fixture + "\n" + fixture, "ns/op")
except ValueError:
    pass
else:
    raise AssertionError("multiple measurements should be explicit")
~~~

<!-- run: python3 gobench.py -->

Compare your decisions with the [historical measurement captures](../../3-tracks/ai-infrastructure/deep-dives/evidence/README.md). Preserve your machine settings and rerun the same baseline whenever the comparison looks too close to call.
