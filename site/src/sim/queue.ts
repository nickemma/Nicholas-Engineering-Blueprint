// One server and one queue, with Poisson arrivals: the M/G/1 queue from the
// maths track. All times are in units of the mean service time.
import { exponential, next, rngOf, type Rng } from "./rng.ts";

// cv2 is the squared coefficient of variation of the service time.
export type Cv2 = 0 | 0.5 | 1 | 4;

export function service(rng: Rng, cv2: Cv2): number {
  if (cv2 === 0) return 1;
  if (cv2 === 1) return exponential(rng, 1);
  // Erlang-2: the sum of two exponentials, half the mean each.
  if (cv2 === 0.5) return exponential(rng, 0.5) + exponential(rng, 0.5);
  // A balanced two-phase hyperexponential with mean 1 and cv2 of 4: mostly
  // short jobs, with a few long ones.
  const p = (1 + Math.sqrt(3 / 5)) / 2;
  return next(rng) < p
    ? exponential(rng, 1 / (2 * p))
    : exponential(rng, 1 / (2 * (1 - p)));
}

// Pollaczek-Khinchine: the mean wait in the queue, before service starts.
export function meanWait(rho: number, cv2: number): number {
  return (rho / (1 - rho)) * ((1 + cv2) / 2);
}

export interface Measured {
  rho: number;
  meanWait: number;
  p95Wait: number;
}

// Lindley's recursion: each job waits for what the last one left behind.
export function simulate(rho: number, cv2: Cv2, n: number, seed: number): Measured {
  const rng = rngOf(seed);
  const warmUp = Math.floor(n / 10);
  const waits = new Float64Array(n - warmUp);
  let wait = 0;
  for (let i = 0; i < n; i++) {
    if (i >= warmUp) waits[i - warmUp] = wait;
    wait = Math.max(0, wait + service(rng, cv2) - exponential(rng, 1 / rho));
  }
  let total = 0;
  for (const w of waits) total += w;
  waits.sort();
  return {
    rho,
    meanWait: total / waits.length,
    p95Wait: waits[Math.floor(waits.length * 0.95)],
  };
}
