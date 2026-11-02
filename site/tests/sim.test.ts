import assert from "node:assert/strict";
import { test } from "node:test";
import { meanWait, simulate, type Cv2 } from "../src/sim/queue.ts";
import { advance, crash, createSim, currentLeader, restart, setSplit } from "../src/sim/raft.ts";
import { next, rngOf } from "../src/sim/rng.ts";

test("the formula matches worked values", () => {
  assert.equal(meanWait(0.5, 1), 1);
  assert.equal(meanWait(0.5, 0), 0.5);
  assert.ok(Math.abs(meanWait(0.9, 1) - 9) < 1e-9);
});

for (const cv2 of [0, 0.5, 1, 4] as Cv2[]) {
  test(`the simulated queue agrees with the formula at cv2 ${cv2}`, () => {
    for (const rho of [0.3, 0.5, 0.7]) {
      const measured = simulate(rho, cv2, 2_000_000, 7).meanWait;
      const expected = meanWait(rho, cv2);
      assert.ok(Math.abs(measured - expected) / expected < 0.03, `rho ${rho}: ${measured} vs ${expected}`);
    }
  });
}

test("a seed replays the same queue", () => {
  assert.deepEqual(simulate(0.7, 1, 10_000, 3), simulate(0.7, 1, 10_000, 3));
});

test("a cluster with randomised timeouts elects a leader", () => {
  for (let seed = 1; seed <= 200; seed++) {
    const sim = createSim(seed);
    advance(sim, 2000);
    assert.ok(currentLeader(sim), `seed ${seed}`);
    assert.deepEqual(sim.violations, []);
  }
});

test("identical timeouts split the vote for ever", () => {
  const sim = createSim(1, false);
  advance(sim, 5000);
  assert.equal(currentLeader(sim), null);
  assert.ok(sim.nodes[0].term > 10);
  assert.deepEqual(sim.violations, []);
});

test("a crashed leader is replaced, and steps down when it returns", () => {
  const sim = createSim(5);
  advance(sim, 2000);
  const old = currentLeader(sim)!;
  crash(sim, old.id);
  advance(sim, 4000);
  const replacement = currentLeader(sim)!;
  assert.notEqual(replacement.id, old.id);
  assert.ok(replacement.term > old.term);
  restart(sim, old.id);
  advance(sim, 6000);
  assert.equal(sim.nodes[old.id].role, "follower");
  assert.equal(sim.nodes[old.id].term, currentLeader(sim)!.term);
});

test("the minority side of a split never elects anyone", () => {
  for (let seed = 1; seed <= 50; seed++) {
    const sim = createSim(seed);
    advance(sim, 2000);
    setSplit(sim, true);
    const before = new Set(sim.leaderOfTerm.keys());
    advance(sim, 8000);
    for (const [term, leader] of sim.leaderOfTerm) {
      if (!before.has(term)) assert.ok(leader >= 2, `seed ${seed}: node ${leader} won term ${term}`);
    }
    setSplit(sim, false);
    advance(sim, 11000);
    assert.equal(sim.nodes.filter((node) => node.role === "leader").length, 1, `seed ${seed}`);
  }
});

test("chaos never breaks election safety, and a healed cluster recovers", () => {
  for (let seed = 1; seed <= 300; seed++) {
    const sim = createSim(seed);
    const rng = rngOf(seed * 31);
    let now = 0;
    for (let round = 0; round < 40; round++) {
      now += 50 + next(rng) * 400;
      advance(sim, now);
      const id = Math.floor(next(rng) * sim.nodes.length);
      const action = next(rng);
      if (action < 0.3) {
        if (sim.nodes[id].alive) crash(sim, id);
        else restart(sim, id);
      } else if (action < 0.45) {
        setSplit(sim, !sim.split);
      }
    }
    assert.deepEqual(sim.violations, [], `seed ${seed}`);
    for (const node of sim.nodes) if (!node.alive) restart(sim, node.id);
    if (sim.split) setSplit(sim, false);
    advance(sim, now + 4000);
    assert.equal(sim.nodes.filter((node) => node.role === "leader").length, 1, `seed ${seed}`);
    assert.deepEqual(sim.violations, [], `seed ${seed}`);
  }
});
