# 04 Benchmark the public API with YCSB

> Distributed KV capstone · Week 2 · Builds on lesson 03

## The problem

A local lookup timer ignores client behavior, network hops, persistence, and consensus. Compare both read paths through the same public interface and count any errors.

## The mental model

One YCSB worker owns each binding instance and its client sequence. The binding sends the same mutation identity when retrying a redirect or an ambiguous response. Each trial uses a fresh three-peer cluster and a separate load phase.

## The pattern

Run YCSB 0.17.0 with workloads A and C over one-field records. Hold record count, field size, key distribution, and concurrency fixed. Alternate the order of the modes across trials. Save the actual read and update counts since YCSB samples the workload mix. [YCSB workloads](https://github.com/brianfrankcooper/YCSB/wiki/Core-Workloads)

## Build it

### Step 1 — Pin the client dependencies

Verify the core jar and each runtime dependency by digest before compiling the binding.

<details>
<summary>Hint</summary>

The cache can be reused across runs. A mismatched jar must fail preparation.

</details>

<details>
<summary>Implementation</summary>

Create `bench/dependencies.tsv`.

<!-- file: bench/dependencies.tsv -->
~~~text
e1c64d09bfc642715428c2e53ec129b0a98a0e634ee32bf0ae77e5b4eebb3cda site/ycsb/core/0.17.0/core-0.17.0.jar
5d45b7904857c3e4ad36b3bcc57be2d2c5f308c69b5f6a58bd86aa7d48a25ef6 org/apache/htrace/htrace-core4/4.1.0-incubating/htrace-core4-4.1.0-incubating.jar
6129e1b91d7850ba250b1375094c8ca215a0f7cf234b6f60a2f4a88d5b1272c9 org/codehaus/jackson/jackson-core-asl/1.9.4/jackson-core-asl-1.9.4.jar
f013389c3eb92aa997df801e4a352464925af634a4af3e5bd77c6c0763dc9c99 org/codehaus/jackson/jackson-mapper-asl/1.9.4/jackson-mapper-asl-1.9.4.jar
8e68b9608ab107690350b904eab24087785f69218e5c6acd860d28116eded708 org/hdrhistogram/HdrHistogram/2.1.4/HdrHistogram-2.1.4.jar
~~~

Create `bench/prepare.sh`.

<!-- file: bench/prepare.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cache=${1:?provide a dependency cache directory}
classes=${2:?provide a Java class output directory}
mkdir -p "$cache" "$classes"
while read -r digest artifact; do
    jar="$cache/${artifact##*/}"
    if [[ ! -f "$jar" ]]; then
        pending=$(mktemp "$cache/.download-XXXXXX")
        trap 'rm -f "$pending"' EXIT
        curl -fsSL --max-time 60 "https://repo.maven.apache.org/maven2/$artifact" -o "$pending"
        echo "$digest  $pending" | sha256sum --check --status
        mv "$pending" "$jar"
        trap - EXIT
    fi
    echo "$digest  $jar" | sha256sum --check --status
done < "$source_dir/dependencies.tsv"
classpath="$cache/core-0.17.0.jar:$cache/htrace-core4-4.1.0-incubating.jar:$cache/jackson-core-asl-1.9.4.jar:$cache/jackson-mapper-asl-1.9.4.jar:$cache/HdrHistogram-2.1.4.jar"
javac -cp "$classpath" -d "$classes" "$source_dir/SwitchyardDB.java"
echo "$classes:$classpath"
~~~

</details>

### Step 2 — Implement the client binding

Map reads to point requests and inserts and updates to one-field writes. Preserve the request identity within one retry loop.

<details>
<summary>Hint</summary>

Follow the leader hint by peer ID when present. Keep retries bounded so failed calls appear in results.

</details>

<details>
<summary>Implementation</summary>

Create `bench/SwitchyardDB.java`.

<!-- file: bench/SwitchyardDB.java -->
~~~java
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.Vector;

import org.codehaus.jackson.JsonNode;
import org.codehaus.jackson.map.ObjectMapper;

import site.ycsb.ByteIterator;
import site.ycsb.DB;
import site.ycsb.DBException;
import site.ycsb.Status;
import site.ycsb.StringByteIterator;

public final class SwitchyardDB extends DB {
  private final ObjectMapper json = new ObjectMapper();
  private final String client = UUID.randomUUID().toString();
  private String[] servers;
  private String token;
  private long sequence;
  private int preferred;

  @Override
  public void init() throws DBException {
    String endpoints = getProperties().getProperty("switchyard.endpoints", "");
    token = getProperties().getProperty("switchyard.token", "");
    servers = endpoints.split(",");
    if (servers.length != 3 || token.isEmpty()) {
      throw new DBException("provide three peer URLs and a fixture token");
    }
  }

  private static final class Reply {
    final Status status;
    final String value;

    Reply(Status status, String value) {
      this.status = status;
      this.value = value;
    }
  }

  private Reply send(String operation, String key, String value) {
    Map<String, Object> request = new HashMap<>();
    request.put("op", operation);
    request.put("key", key);
    if (!operation.equals("get")) {
      request.put("client", client);
      request.put("sequence", ++sequence);
      if (value != null) {
        request.put("value", value);
      }
    }
    for (int attempt = 0; attempt < 6; ++attempt) {
      HttpURLConnection connection = null;
      int next = (preferred + 1) % servers.length;
      try {
        connection = (HttpURLConnection) URI.create(servers[preferred] + "/kv").toURL().openConnection();
        connection.setConnectTimeout(800);
        connection.setReadTimeout(1800);
        connection.setRequestMethod("POST");
        connection.setRequestProperty("Authorization", "Bearer " + token);
        connection.setRequestProperty("Content-Type", "application/json");
        connection.setDoOutput(true);
        byte[] encoded = json.writeValueAsBytes(request);
        connection.setFixedLengthStreamingMode(encoded.length);
        try (var output = connection.getOutputStream()) {
          output.write(encoded);
        }
        int code = connection.getResponseCode();
        try (var input = code < 400 ? connection.getInputStream() : connection.getErrorStream()) {
          byte[] body = input == null ? new byte[0] : input.readNBytes(8193);
          if (body.length > 8192) {
            return new Reply(Status.ERROR, null);
          }
          if (code == 200) {
            JsonNode response = json.readTree(body);
            if (response.has("error") || !response.has("found")) {
              return new Reply(Status.ERROR, null);
            }
            if (!response.get("found").asBoolean()) {
              return new Reply(Status.NOT_FOUND, null);
            }
            return new Reply(Status.OK, response.has("value") ? response.get("value").asText() : "");
          }
          if (code == 409 && body.length != 0) {
            JsonNode leader = json.readTree(body).get("leader");
            if (leader != null && leader.asInt() >= 1 && leader.asInt() <= servers.length) {
              next = leader.asInt() - 1;
            }
          } else if (code != 503 && code != 504) {
            return new Reply(Status.ERROR, null);
          }
        }
      } catch (IOException failure) {
        // An interrupted response can be retried with the original sequence.
      } finally {
        if (connection != null) {
          connection.disconnect();
        }
      }
      preferred = next;
    }
    return new Reply(Status.ERROR, null);
  }

  @Override
  public Status read(String table, String key, Set<String> fields, Map<String, ByteIterator> result) {
    if (fields != null && !fields.equals(Set.of("field0"))) {
      return Status.NOT_IMPLEMENTED;
    }
    Reply response = send("get", table + ":" + key, null);
    if (response.status.isOk() && result != null) {
      result.put("field0", new StringByteIterator(response.value));
    }
    return response.status;
  }

  @Override
  public Status update(String table, String key, Map<String, ByteIterator> values) {
    ByteIterator value = values.get("field0");
    if (values.size() != 1 || value == null) {
      return Status.NOT_IMPLEMENTED;
    }
    return send("put", table + ":" + key, new String(value.toArray(), StandardCharsets.UTF_8)).status;
  }

  @Override
  public Status insert(String table, String key, Map<String, ByteIterator> values) {
    return update(table, key, values);
  }

  @Override
  public Status delete(String table, String key) {
    return send("delete", table + ":" + key, null).status;
  }

  @Override
  public Status scan(String table, String key, int count, Set<String> fields,
      Vector<HashMap<String, ByteIterator>> result) {
    return Status.NOT_IMPLEMENTED;
  }
}
~~~

</details>

### Step 3 — Match the workload settings

Use an update-heavy and a read-only workload. Keep configuration files beside the binding.

<details>
<summary>Hint</summary>

Leave raw client output separate from the load phase. Operation status counts matter as much as throughput.

</details>

<details>
<summary>Implementation</summary>

Create `bench/workloada.properties`.

<!-- file: bench/workloada.properties -->
~~~text
workload=site.ycsb.workloads.CoreWorkload
readproportion=0.5
updateproportion=0.5
insertproportion=0
scanproportion=0
readmodifywriteproportion=0
requestdistribution=uniform
fieldcount=1
fieldlength=64
readallfields=true
writeallfields=true
measurementtype=histogram
~~~

Create `bench/workloadc.properties`.

<!-- file: bench/workloadc.properties -->
~~~text
workload=site.ycsb.workloads.CoreWorkload
readproportion=1
updateproportion=0
insertproportion=0
scanproportion=0
readmodifywriteproportion=0
requestdistribution=uniform
fieldcount=1
fieldlength=64
readallfields=true
writeallfields=true
measurementtype=histogram
~~~

</details>

### Step 4 — Collect all outcomes

Verify the loaded record count, measured operation count, and every return status. Save a JSON summary beside the YCSB output.

<details>
<summary>Hint</summary>

A zero process exit alone does not establish zero failed operations.

</details>

<details>
<summary>Implementation</summary>

Create `lab/benchmark.py`.

<!-- file: lab/benchmark.py -->
~~~python
"""Run the official YCSB client through the public loopback endpoint."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from capstone import KVCluster, ok


def run_java(classpath, properties, phase, size, requests, threads):
    command = ["java", "-cp", classpath, "site.ycsb.Client", f"-{phase}", "-db", "SwitchyardDB",
               "-P", str(properties), "-threads", str(threads), "-p", f"recordcount={size}",
               "-p", f"operationcount={requests}", "-p", "maxexecutiontime=60"]
    done = subprocess.run(command, capture_output=True, text=True, timeout=80)
    if done.returncode:
        raise AssertionError(done.stdout + done.stderr)
    return done.stdout


def metrics(raw):
    found = {}
    for line in raw.splitlines():
        if line.startswith("["):
            name, field, number = line.split(", ", 2)
            found.setdefault(name.strip("[]"), {})[field] = float(number)
    return found


def count_success(data, operations, expected):
    completed = 0
    for name in operations:
        bucket = data.get(name, {})
        count = int(bucket.get("Operations", 0))
        success = int(bucket.get("Return=OK", 0))
        assert success == count, (name, bucket)
        rejected = {label: n for label, n in bucket.items() if label.startswith("Return=") and label != "Return=OK" and n}
        assert not rejected, rejected
        completed += count
    assert completed == expected, (completed, expected, operations)


def trial(paths, read_path, letter, output, number, size, requests, threads):
    peer, writer, engine, classpath = paths
    with tempfile.TemporaryDirectory(prefix="sy-ycsb-", dir="/tmp") as temporary:
        root = Path(temporary)
        with KVCluster(root, peer, writer, engine, read_path) as cluster:
            leader = cluster.leader()["ID"]
            ok(cluster, leader, "put", "fixture", "same", 1)
            assert ok(cluster, leader, "get", "fixture") == {"found": True, "value": "same"}
            assert ok(cluster, leader, "get", "fixture", tenant="b") == {"found": False}
            endpoints = ",".join("http://" + cluster.address(p) for p in cluster.ids)
            profile = (Path(__file__).resolve().parent.parent / "bench" / f"workload{letter}.properties").read_text()
            properties = root / "fixture.properties"
            # Secrets stay in a mode-0600 temporary property file and out of evidence.
            fd = os.open(properties, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, "w") as stream:
                stream.write(profile + f"switchyard.endpoints={endpoints}\nswitchyard.token={cluster.tokens['a']}\n")
            loaded = run_java(classpath, properties, "load", size, requests, 1)
            count_success(metrics(loaded), ["INSERT"], size)
            measured = run_java(classpath, properties, "t", size, requests, threads)
            stats = metrics(measured)
            operations = ["READ", "UPDATE"] if letter == "a" else ["READ"]
            count_success(stats, operations, requests)
            observed = {operation: stats[operation]["Operations"] for operation in operations if operation in stats}
            assert all(value > 0 for value in observed.values()) and len(observed) == len(operations), observed
            prefix = f"{number}-{read_path}-{letter}"
            # The YCSB command banner is on stderr and includes the temporary properties path.
            (output / f"{prefix}-load.txt").write_text(loaded)
            (output / f"{prefix}.txt").write_text(measured)
            result = {
                "trial": number, "path": read_path, "workload": letter, "records": size,
                "requests": requests, "threads": threads, "errors": 0, "counts": observed,
                "throughput": stats["OVERALL"]["Throughput(ops/sec)"],
                "read_p95_us": stats["READ"]["95thPercentileLatency(us)"],
                "read_p99_us": stats["READ"]["99thPercentileLatency(us)"],
            }
            print(json.dumps(result), flush=True)
            return result


def main():
    peer, writer, engine, classpath, folder, mode = sys.argv[1:]
    output = Path(folder).resolve()
    output.mkdir(parents=True, exist_ok=True)
    paths = (Path(peer).resolve(), Path(writer).resolve(), Path(engine).resolve(), classpath)
    size, requests, threads, trials = (32, 32, 2, 1) if mode == "smoke" else (64, 400, 2, 2)
    rows = []
    for repetition in range(1, trials + 1):
        for letter in ("a", "c"):
            modes = ("range", "point") if repetition % 2 else ("point", "range")
            for path in modes:
                rows.append(trial(paths, path, letter, output, repetition, size, requests, threads))
    (output / "matrix.json").write_text(json.dumps(rows, indent=2) + "\n")


if __name__ == "__main__":
    main()
~~~

</details>

## Check it

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/05-capstone-distributed-kv-store/gate/run.sh" "$PWD" benchmark
~~~

The full matrix records two trials per workload and path. The reference counted 3,200 measured operations across those trials. [Raw runs and summaries](../evidence/README.md)

## If it goes wrong

If YCSB reports a missing class, use the pinned class path from preparation. If it reports fewer operations than requested, inspect latency and return-status lines before comparing throughput.
