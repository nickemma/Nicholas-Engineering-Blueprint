import assert from "node:assert/strict";
import { test } from "node:test";
import * as anomaly from "../src/sim/anomaly.ts";
import * as audit from "../src/sim/audit.ts";
import * as burn from "../src/sim/burnrate.ts";
import * as cluster from "../src/sim/controlloop.ts";
import * as drift from "../src/sim/drift.ts";
import * as retry from "../src/sim/retrystorm.ts";
import * as rollout from "../src/sim/rollout.ts";
import * as log from "../src/sim/tornlog.ts";

// Rollouts

function rolled(bug: rollout.Bug, deepProbe: boolean, maxSurge = 1, maxUnavailable = 0, ticks = 60) {
  const r = rollout.createRollout({ desired: 4, maxSurge, maxUnavailable, bug, deepProbe });
  rollout.deploy(r);
  for (let i = 0; i < ticks; i++) rollout.step(r);
  return r;
}

test("a good release completes, and never drops below the floor", () => {
  for (const [surge, unavailable] of [[1, 0], [2, 0], [0, 1], [1, 1], [2, 2]]) {
    const r = rolled("none", true, surge, unavailable);
    assert.ok(rollout.isComplete(r), `${surge}/${unavailable}`);
    assert.ok(r.history.every((sample) => sample.ready >= 4 - unavailable), `${surge}/${unavailable}`);
    assert.ok(r.history.every((sample) => sample.errorRate === 0));
  }
});

test("a release that crashes stalls, and users never see it", () => {
  const r = rolled("crash", true);
  assert.ok(rollout.isStalled(r));
  assert.ok(!rollout.isComplete(r));
  assert.ok(r.history.every((sample) => sample.served === 1));
});

test("a shallow probe lets a broken release through; a deep one doesn't", () => {
  const shallow = rolled("errors", false);
  assert.ok(rollout.isComplete(shallow));
  assert.equal(shallow.history.at(-1)!.errorRate, 1);
  const deep = rolled("errors", true);
  assert.ok(rollout.isStalled(deep));
  assert.equal(deep.history.at(-1)!.errorRate, 0);
});

test("rolling back recovers a broken release", () => {
  const r = rolled("errors", false);
  rollout.rollBack(r);
  for (let i = 0; i < 60; i++) rollout.step(r);
  assert.ok(rollout.isComplete(r));
  assert.ok(r.pods.every((pod) => pod.version === 1));
  assert.equal(r.history.at(-1)!.served, 1);
});

test("a rollout that can't move is refused", () => {
  assert.throws(() => rollout.createRollout({ desired: 4, maxSurge: 0, maxUnavailable: 0, bug: "none", deepProbe: true }));
});

// The control loop

const settle = (c: cluster.Cluster, ticks = 20) => {
  for (let i = 0; i < ticks; i++) cluster.step(c);
};

test("the controller replaces a killed Pod", () => {
  const c = cluster.createCluster(6);
  cluster.killPod(c, c.pods[0].id);
  settle(c);
  assert.equal(cluster.serving(c), 6);
});

test("level-triggered: a stopped controller misses events and still ends up right", () => {
  const c = cluster.createCluster(6);
  cluster.setController(c, false);
  for (const pod of c.pods.slice(0, 3)) cluster.killPod(c, pod.id);
  settle(c);
  assert.equal(c.pods.length, 3);
  cluster.setController(c, true);
  settle(c);
  assert.equal(cluster.serving(c), 6);
});

test("a dead node's Pods come back elsewhere, and nothing overfills a node", () => {
  const c = cluster.createCluster(6);
  cluster.setNodeUp(c, "node-1", false);
  settle(c);
  assert.equal(cluster.serving(c), 6);
  assert.ok(c.pods.every((pod) => pod.node !== "node-1"));
  for (const node of c.nodes) {
    assert.ok(c.pods.filter((pod) => pod.node === node.name).length <= cluster.CAPACITY);
  }
});

test("more Pods than room stay Pending, and scaling down clears them first", () => {
  const c = cluster.createCluster(6);
  cluster.setDesired(c, 15);
  settle(c);
  assert.equal(cluster.serving(c), 12);
  assert.equal(c.pods.filter((pod) => pod.phase === "pending").length, 3);
  cluster.setDesired(c, 12);
  settle(c);
  assert.equal(c.pods.filter((pod) => pod.phase === "pending").length, 0);
  assert.equal(cluster.serving(c), 12);
});

test("a drain moves the Pods and keeps new ones off", () => {
  const c = cluster.createCluster(6);
  cluster.drain(c, "node-2");
  settle(c);
  assert.equal(cluster.serving(c), 6);
  assert.ok(c.pods.every((pod) => pod.node !== "node-2"));
});

// Burn rate

const run = (incident: Omit<burn.Incident, "start">) => {
  const errors = burn.errorSeries([{ start: 1440, ...incident }]);
  const fired = (name: string) => burn.evaluate(errors, burn.RULES.find((rule) => rule.name === name)!);
  return { errors, page: fired("Page"), ticket: fired("Ticket") };
};

test("the guide's budget numbers", () => {
  assert.ok(Math.abs(burn.BUDGET * burn.MONTH - 43.2) < 1e-9);
  const hour = burn.errorSeries([{ start: 0, minutes: 60, errorRate: 14.4 * burn.BUDGET }]);
  assert.ok(Math.abs(burn.budgetSpent(hour).at(-1)! - 0.02) < 1e-9);
});

test("a full outage pages within minutes", () => {
  const { page, errors } = run({ minutes: 10, errorRate: 1 });
  assert.equal(page.length, 1);
  assert.ok(page[0].from - 1440 <= 6, String(page[0].from - 1440));
  assert.ok(Math.abs(burn.budgetSpent(errors).at(-1)! - 10 / 43.2) < 1e-9);
});

test("the short windows stop the page about half an hour after the outage ends", () => {
  // The slower rule's short window is 30 minutes. Its long window alone would
  // hold the page for six hours.
  const { page } = run({ minutes: 10, errorRate: 1 });
  const after = page[0].to - (1440 + 10);
  assert.ok(after > 25 && after <= 31, String(after));
});

test("a small blip fires the naive alert and nothing else", () => {
  const { errors, page, ticket } = run({ minutes: 5, errorRate: 0.05 });
  assert.equal(page.length, 0);
  assert.equal(ticket.length, 0);
  assert.ok(burn.naive(errors).length > 0);
});

test("a slow leak opens a ticket without paging anyone", () => {
  const { page, ticket } = run({ minutes: 3 * 1440, errorRate: 0.004 });
  assert.equal(page.length, 0);
  assert.equal(ticket.length, 1);
});

// The retry storm

const storm = (policy: retry.Policy) => retry.run({ policy, load: 0.8, slowdown: 0.4 });

test("healthy traffic is all answered", () => {
  const r = retry.run({ policy: "immediate", load: 0.8, slowdown: 1 });
  assert.ok(r.seconds.every((row) => Math.abs(row.goodput - 0.8) < 1e-6));
  assert.ok(r.seconds.every((row) => row.wasted === 0));
});

test("without retries the backlog drains and the system recovers", () => {
  // 20 s at 40 requests a second too many is 800 queued, draining at 20 a second.
  const r = storm("none");
  assert.notEqual(r.recoveredAt, null);
  assert.ok(r.recoveredAt! > 30 && r.recoveredAt! <= 40, String(r.recoveredAt));
});

test("immediate retries keep the system down after the cause has gone", () => {
  const r = storm("immediate");
  assert.equal(r.recoveredAt, null);
  assert.ok(r.seconds.at(-1)!.offered > 1, String(r.seconds.at(-1)!.offered));
});

test("backoff and jitter alone don't recover from sustained overload", () => {
  // They spread retries out in time. They don't reduce how many there are.
  const r = storm("backoff");
  assert.equal(r.recoveredAt, null);
  assert.ok(r.seconds.at(-1)!.offered > 3, String(r.seconds.at(-1)!.offered));
});

test("the breaker sheds load and recovers", () => {
  const r = storm("breaker");
  assert.notEqual(r.recoveredAt, null);
  assert.ok(r.seconds.some((row) => row.breakerOpen));
  assert.ok(!r.seconds.at(-1)!.breakerOpen);
});

// The log

test("CRC-32C matches the standard check value", () => {
  assert.equal(log.crc32c(new TextEncoder().encode("123456789")), 0xe3069283);
});

test("records round-trip, and fsync decides what survives", () => {
  let file = log.createLog();
  file = log.fsync(log.write(file, "one"));
  file = log.write(file, "two");
  const lost = log.recover(log.powerCut(file, 0));
  assert.deepEqual(lost, { status: "ok", records: ["one"], validLength: file.durable.length, truncated: 0 });
  const all = log.recover(log.powerCut(file, file.cached.length));
  assert.equal(all.status, "ok");
  assert.deepEqual(all.records, ["one", "two"]);
});

test("every possible tear recovers the records before it", () => {
  let file = log.fsync(log.write(log.createLog(), "alpha"));
  file = log.write(file, "beta");
  for (let cut = 0; cut < file.cached.length; cut++) {
    const result = log.recover(log.powerCut(file, cut));
    assert.equal(result.status, "ok", `cut at ${cut}`);
    assert.deepEqual(result.records, ["alpha"], `cut at ${cut}`);
    if (result.status === "ok") assert.equal(result.truncated, cut);
  }
});

test("damage in the last record is torn; damage before valid data is refused", () => {
  let file = log.createLog();
  for (const word of ["a", "b", "c"]) file = log.write(file, word);
  const data = log.fsync(file).durable;
  const last = log.recover(log.flipByte(data, data.length - 1));
  assert.equal(last.status, "ok");
  assert.deepEqual(last.records, ["a", "b"]);
  const middle = log.recover(log.flipByte(data, log.HEADER_LEN));
  assert.equal(middle.status, "refused");
  if (middle.status === "refused") assert.equal(middle.offset, 0);
});

test("a corrupted length is refused rather than trusted", () => {
  const data = log.fsync(log.write(log.write(log.createLog(), "a"), "b")).durable;
  assert.equal(log.recover(log.flipByte(data, 3)).status, "refused");
});

// The audit log

const fromHex = (text: string) => Uint8Array.from(text.match(/../g) ?? [], (pair) => parseInt(pair, 16));

// The test vectors of Certificate Transparency's Merkle tree.
const VECTORS = ["", "00", "10", "2021", "3031", "40414243", "5051525354555657", "606162636465666768696a6b6c6d6e6f"];

test("the tree matches the published vectors", async () => {
  assert.equal(audit.hex(await audit.root([])), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  assert.equal(audit.hex(await audit.leafHash(new Uint8Array())), "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d");
  const leaves = await Promise.all(VECTORS.map((vector) => audit.leafHash(fromHex(vector))));
  assert.equal(audit.hex(await audit.root(leaves)), "5dc9da79a70659a9ad559cb701ded9a2ab9d823aad2f4960cfe370eff4604328");
});

test("every inclusion proof verifies, and is about log n long", async () => {
  for (const size of [1, 2, 3, 5, 7, 8, 13]) {
    const leaves = await Promise.all(Array.from({ length: size }, (_, i) => audit.leafHash(audit.textBytes(`r${i}`))));
    const tree = await audit.root(leaves);
    for (let i = 0; i < size; i++) {
      const proof = await audit.inclusionProof(leaves, i);
      assert.ok(proof.length <= Math.ceil(Math.log2(size)));
      assert.ok(await audit.verifyInclusion(leaves[i], i, size, proof, tree), `${i} of ${size}`);
      if (size > 1) {
        const wrong = await audit.leafHash(audit.textBytes("forged"));
        assert.ok(!(await audit.verifyInclusion(wrong, i, size, proof, tree)));
      }
    }
  }
});

test("a rewritten chain still verifies; the witness catches it", async () => {
  const records = ["login alice", "read job 12", "delete job 12", "logout alice"];
  const checkpoint = await audit.checkpointOf(records);
  const links = await audit.chain(records);

  const edited = ["login alice", "read job 12", "read job 13", "logout alice"];
  assert.equal(await audit.verifyChain(edited, links), 2);

  const rewritten = await audit.chain(edited);
  assert.equal(await audit.verifyChain(edited, rewritten), null);
  assert.equal(await audit.witnessAccepts(edited, checkpoint), false);
});

test("appending is all a witness accepts", async () => {
  const records = ["a", "b", "c"];
  const checkpoint = await audit.checkpointOf(records);
  assert.equal(await audit.witnessAccepts([...records, "d"], checkpoint), true);
  assert.equal(await audit.witnessAccepts(["a", "b"], checkpoint), false);
  assert.equal(await audit.witnessAccepts(["b", "a", "c"], checkpoint), false);
});

// Drift

const reference = drift.reference(drift.sample(1, 0, 1));

test("new data from the same distribution is stable", () => {
  const live = drift.sample(2, 0, 1);
  const value = drift.psi(reference.shares, drift.sharesOf(reference.edges, live));
  assert.ok(value < 0.1, String(value));
  assert.equal(drift.verdict(value), "stable");
  assert.ok(drift.ks(reference.sorted, live) < 0.05);
});

test("a shifted distribution is a major drift", () => {
  const live = drift.sample(2, 1, 1);
  const value = drift.psi(reference.shares, drift.sharesOf(reference.edges, live));
  assert.equal(drift.verdict(value), "major");
  assert.ok(drift.ks(reference.sorted, live) > 0.3);
});

test("the verdict's edges match the guide", () => {
  assert.equal(drift.verdict(0.099), "stable");
  assert.equal(drift.verdict(0.25), "moderate");
  assert.equal(drift.verdict(0.26), "major");
});

test("concept drift is invisible to PSI but not to the error", () => {
  const live = drift.sample(2, 0, 1);
  const value = drift.psi(reference.shares, drift.sharesOf(reference.edges, live));
  assert.equal(drift.verdict(value), "stable");
  assert.equal(drift.meanError(live, 2, 2), 0);
  assert.ok(drift.meanError(live, 2, 3) > 0.5);
});

// Anomaly detection

test("a known set of alarms scores as worked out by hand", () => {
  const incidents = [{ start: 300, minutes: 10, name: "x" }, { start: 500, minutes: 10, name: "y" }];
  const score = anomaly.evaluate([{ from: 303, to: 305 }, { from: 400, to: 402 }], incidents);
  assert.equal(score.recall, 0.5);
  assert.equal(score.precision, 0.5);
  assert.equal(score.falseAlarms, 1);
  assert.equal(score.meanDetect, 3);
  assert.equal(score.covered, 0.1);
});

test("alarms need a run of minutes, and never fire in the warm-up", () => {
  const scored = new Float64Array(anomaly.MINUTES);
  scored.fill(9, 100, 110);
  scored[300] = 9;
  scored.fill(9, 400, 403);
  assert.deepEqual(anomaly.alarms(scored, 5, 2), [{ from: 401, to: 403 }]);
});

test("spikes in the warm-up stretch the mean's scale, not the median's", () => {
  const values = anomaly.signal(3);
  const warm = [...values.subarray(0, anomaly.WARM_UP)];
  assert.ok(Math.max(...warm) > 130, "the warm-up should hold spikes");
  const threshold = anomaly.scores(values, "threshold");
  const mad = anomaly.scores(values, "mad");
  const t = anomaly.INCIDENTS[0].start + 5;
  assert.ok(mad[t] > threshold[t] * 1.3, `${mad[t]} vs ${threshold[t]}`);
});

test("one huge value doesn't blind EWMA to what follows", () => {
  const values = anomaly.signal(3).slice();
  const t = anomaly.WARM_UP + 20;
  values[t] = 5000;
  values[t + 1] = 200;
  const scored = anomaly.scores(values, "ewma");
  assert.ok(scored[t + 1] > 5, String(scored[t + 1]));
});

test("at the guide's limit of 5, the median finds every incident on every day", () => {
  for (const seed of [3, 4, 5, 6]) {
    const scored = anomaly.scores(anomaly.signal(seed), "mad");
    assert.equal(anomaly.evaluate(anomaly.alarms(scored, 5, 2), anomaly.INCIDENTS).found, 3, `seed ${seed}`);
  }
});

test("the mean's results swing with what the warm-up held", () => {
  const found = [3, 4, 5, 6].map((seed) =>
    anomaly.evaluate(anomaly.alarms(anomaly.scores(anomaly.signal(seed), "threshold"), 5, 2), anomaly.INCIDENTS).found,
  );
  assert.ok(Math.max(...found) - Math.min(...found) >= 2, found.join());
});

test("EWMA gets used to an incident that lasts", () => {
  const values = anomaly.signal(3);
  const scored = anomaly.scores(values, "ewma");
  const plateau = anomaly.INCIDENTS[2];
  const early = scored.subarray(plateau.start, plateau.start + 5).reduce((a, b) => a + b, 0);
  const late = scored.subarray(plateau.start + 100, plateau.start + 105).reduce((a, b) => a + b, 0);
  assert.ok(early > late * 3, `${early} vs ${late}`);
});
