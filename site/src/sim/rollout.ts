// A rolling update, as a Deployment controller does it: one tick is a second.
// Version 1 is the running release, and version 2 is the new one.

export type Bug = "none" | "crash" | "errors";
export type Phase = "starting" | "ready" | "failing";

export const START_TICKS = 3;
export const DEADLINE_TICKS = 10;

export interface Pod {
  id: number;
  version: number;
  phase: Phase;
  age: number;
}

export interface Sample {
  tick: number;
  ready: number;
  errorRate: number; // the share of requests that fail
  served: number; // the share of the normal traffic answered well
}

export interface Rollout {
  tick: number;
  desired: number;
  maxSurge: number;
  maxUnavailable: number;
  bug: Bug;
  deepProbe: boolean; // readiness checks what clients need, not just the port
  target: number;
  pods: Pod[];
  nextId: number;
  lastProgress: number;
  newReady: number;
  history: Sample[];
}

export function createRollout(options: {
  desired: number;
  maxSurge: number;
  maxUnavailable: number;
  bug: Bug;
  deepProbe: boolean;
}): Rollout {
  if (options.maxSurge === 0 && options.maxUnavailable === 0) {
    throw new Error("maxSurge and maxUnavailable can't both be 0: nothing could ever move");
  }
  const rollout: Rollout = {
    ...options,
    tick: 0,
    target: 1,
    pods: [],
    nextId: 0,
    lastProgress: 0,
    newReady: 0,
    history: [],
  };
  for (let i = 0; i < options.desired; i++) {
    rollout.pods.push({ id: rollout.nextId++, version: 1, phase: "ready", age: START_TICKS });
  }
  record(rollout);
  return rollout;
}

const isBad = (rollout: Rollout, version: number) => version === 2 && rollout.bug !== "none";

function settle(rollout: Rollout, pod: Pod) {
  if (pod.phase !== "starting" || pod.age < START_TICKS) return;
  const failsItsProbe =
    isBad(rollout, pod.version) && (rollout.bug === "crash" || rollout.deepProbe);
  pod.phase = failsItsProbe ? "failing" : "ready";
}

function control(rollout: Rollout) {
  const { desired, maxSurge, maxUnavailable, target } = rollout;
  const isOld = (pod: Pod) => pod.version !== target;
  // Pods of an old version that aren't serving are removed first: they count
  // for nothing.
  rollout.pods = rollout.pods.filter((pod) => !(isOld(pod) && pod.phase !== "ready"));

  const current = rollout.pods.filter((pod) => !isOld(pod)).length;
  const room = desired + maxSurge - rollout.pods.length;
  const create = Math.min(Math.max(room, 0), desired - current);
  for (let i = 0; i < create; i++) {
    rollout.pods.push({ id: rollout.nextId++, version: target, phase: "starting", age: 0 });
  }

  const available = rollout.pods.filter((pod) => pod.phase === "ready").length;
  let removable = available - (desired - maxUnavailable);
  for (const pod of rollout.pods.filter(isOld)) {
    if (removable <= 0) break;
    rollout.pods = rollout.pods.filter((other) => other !== pod);
    removable -= 1;
  }
}

function record(rollout: Rollout) {
  const ready = rollout.pods.filter((pod) => pod.phase === "ready");
  const bad = ready.filter((pod) => isBad(rollout, pod.version)).length;
  const errorRate = ready.length === 0 ? 1 : bad / ready.length;
  rollout.history.push({
    tick: rollout.tick,
    ready: ready.length,
    errorRate,
    served: Math.min(1, ready.length / rollout.desired) * (1 - errorRate),
  });
}

export function step(rollout: Rollout) {
  rollout.tick += 1;
  for (const pod of rollout.pods) {
    pod.age += 1;
    settle(rollout, pod);
  }
  control(rollout);
  const newReady = rollout.pods.filter(
    (pod) => pod.version === rollout.target && pod.phase === "ready",
  ).length;
  if (newReady !== rollout.newReady) rollout.lastProgress = rollout.tick;
  rollout.newReady = newReady;
  record(rollout);
}

function retarget(rollout: Rollout, version: number) {
  rollout.target = version;
  rollout.lastProgress = rollout.tick;
  rollout.newReady = rollout.pods.filter(
    (pod) => pod.version === version && pod.phase === "ready",
  ).length;
}

export const deploy = (rollout: Rollout) => retarget(rollout, 2);
export const rollBack = (rollout: Rollout) => retarget(rollout, 1);

export function isComplete(rollout: Rollout): boolean {
  return (
    rollout.pods.length === rollout.desired &&
    rollout.pods.every((pod) => pod.version === rollout.target && pod.phase === "ready")
  );
}

// Kubernetes reports this as ProgressDeadlineExceeded. It reports it and stops
// there: rolling back is someone's decision.
export function isStalled(rollout: Rollout): boolean {
  return !isComplete(rollout) && rollout.tick - rollout.lastProgress >= DEADLINE_TICKS;
}
