// Clients calling a dependency that gets slow for a while. Requests wait in a
// queue, and a client gives up after a timeout, but the dependency doesn't know
// that: it still does the work for a client who has left. Counts are fractions,
// so a run is exact and needs no random numbers. Jitter spreads a retry evenly
// across its window.

export type Policy = "none" | "immediate" | "backoff" | "breaker";

const TICK = 0.1; // seconds
const CAPACITY = 100; // requests a second, when healthy
const TIMEOUT = 1;
const MAX_RETRIES = 3;
const BACKOFF_BASE = 0.1;
const BACKOFF_CAP = 2;
const COOL_DOWN = 5;
const BREAKER_WINDOW = 1;
const BREAKER_MIN_CALLS = 10;

interface Cohort {
  born: number;
  count: number;
  attempt: number;
  expired: boolean;
  trial: boolean;
}

export interface RetryOptions {
  policy: Policy;
  load: number; // share of the healthy capacity
  slowdown: number; // share of capacity left during the incident
  seconds?: number;
  incidentStart?: number;
  incidentEnd?: number;
}

export interface Second {
  t: number;
  offered: number; // requests sent, as a share of healthy capacity
  goodput: number; // answers that reached a waiting client, the same way
  wasted: number; // work done for clients who had already left
  rejected: number; // refused at once by the breaker
  breakerOpen: boolean;
}

export interface RetryRun {
  seconds: Second[];
  recoveredAt: number | null; // seconds after the incident ended
}

export function run(options: RetryOptions): RetryRun {
  const {
    policy,
    load,
    slowdown,
    seconds = 90,
    incidentStart = 15,
    incidentEnd = 35,
  } = options;
  const ticks = Math.round(seconds / TICK);
  const due = new Float64Array(ticks + 1).fill(0);
  const dueAttempts = new Map<number, Map<number, number>>();
  const queue: Cohort[] = [];
  const rows: Second[] = [];

  let breaker: "closed" | "open" | "half-open" = "closed";
  let reopenAt = 0;
  let trialOut = false;
  const outcomes: { at: number; ok: number; failed: number }[] = [];

  let offered = 0;
  let goodput = 0;
  let wasted = 0;
  let rejected = 0;
  let opened = false;

  const schedule = (tick: number, attempt: number, count: number) => {
    if (tick > ticks) return;
    due[tick] += count;
    const byAttempt = dueAttempts.get(tick) ?? new Map<number, number>();
    byAttempt.set(attempt, (byAttempt.get(attempt) ?? 0) + count);
    dueAttempts.set(tick, byAttempt);
  };

  const retry = (tick: number, attempt: number, count: number) => {
    if (policy === "none" || attempt >= MAX_RETRIES) return;
    const next = attempt + 1;
    if (policy === "immediate") {
      schedule(tick + 1, next, count);
      return;
    }
    // Full jitter: anywhere between now and the ceiling.
    const ceiling = Math.min(BACKOFF_CAP, BACKOFF_BASE * 2 ** attempt);
    const steps = Math.max(1, Math.round(ceiling / TICK));
    for (let i = 1; i <= steps; i++) schedule(tick + i, next, count / steps);
  };

  const admit = (now: number, count: number, attempt: number) => {
    if (policy === "breaker" && breaker !== "closed") {
      if (breaker === "half-open" && !trialOut) {
        trialOut = true;
        queue.push({ born: now, count: 1, attempt, expired: false, trial: true });
        offered += 1;
        rejected += Math.max(0, count - 1);
        return;
      }
      rejected += count;
      return;
    }
    offered += count;
    queue.push({ born: now, count, attempt, expired: false, trial: false });
  };

  const settleTrial = (ok: boolean, now: number) => {
    trialOut = false;
    if (ok) {
      breaker = "closed";
      outcomes.length = 0;
    } else {
      breaker = "open";
      reopenAt = now + COOL_DOWN;
    }
  };

  for (let tick = 0; tick < ticks; tick++) {
    const now = tick * TICK;
    if (breaker === "open" && now >= reopenAt) breaker = "half-open";

    admit(now, load * CAPACITY * TICK, 0);
    for (const [attempt, count] of dueAttempts.get(tick) ?? []) admit(now, count, attempt);
    dueAttempts.delete(tick);

    const incident = now >= incidentStart && now < incidentEnd;
    let budget = CAPACITY * TICK * (incident ? slowdown : 1);
    let ok = 0;
    let failed = 0;
    while (budget > 1e-9 && queue.length > 0) {
      const cohort = queue[0];
      const served = Math.min(budget, cohort.count);
      budget -= served;
      cohort.count -= served;
      if (cohort.expired) {
        wasted += served;
      } else {
        goodput += served;
        ok += served;
        if (cohort.trial) settleTrial(true, now);
      }
      if (cohort.count <= 1e-9) queue.shift();
    }

    for (const cohort of queue) {
      if (cohort.expired) continue;
      if (now - cohort.born < TIMEOUT) break; // the queue is oldest first
      cohort.expired = true;
      failed += cohort.count;
      if (cohort.trial) settleTrial(false, now);
      retry(tick, cohort.attempt, cohort.count);
    }

    if (policy === "breaker") {
      outcomes.push({ at: now, ok, failed });
      while (outcomes.length > 0 && outcomes[0].at <= now - BREAKER_WINDOW) outcomes.shift();
      const good = outcomes.reduce((sum, row) => sum + row.ok, 0);
      const bad = outcomes.reduce((sum, row) => sum + row.failed, 0);
      if (breaker === "closed" && good + bad >= BREAKER_MIN_CALLS && bad > good) {
        breaker = "open";
        reopenAt = now + COOL_DOWN;
      }
    }
    opened ||= breaker !== "closed";

    if ((tick + 1) % Math.round(1 / TICK) === 0) {
      rows.push({
        t: Math.round(now + TICK),
        offered: offered / CAPACITY,
        goodput: goodput / CAPACITY,
        wasted: wasted / CAPACITY,
        rejected: rejected / CAPACITY,
        breakerOpen: opened,
      });
      offered = goodput = wasted = rejected = 0;
      opened = false;
    }
  }

  // Recovered: the goodput is back at the load, and stays there.
  let recoveredAt: number | null = null;
  const after = rows.filter((row) => row.t > incidentEnd);
  for (let i = after.length - 1; i >= 0 && after[i].goodput >= load * 0.95; i--) {
    recoveredAt = after[i].t - incidentEnd;
  }
  return { seconds: rows, recoveredAt };
}
