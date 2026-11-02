// A small seeded generator, so that a simulation can be replayed exactly.
export interface Rng {
  state: number;
}

export function rngOf(seed: number): Rng {
  return { state: seed >>> 0 };
}

// mulberry32: returns a float in [0, 1).
export function next(rng: Rng): number {
  rng.state = (rng.state + 0x6d2b79f5) >>> 0;
  let t = rng.state;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}

export function exponential(rng: Rng, mean: number): number {
  return -Math.log(1 - next(rng)) * mean;
}

export function between(rng: Rng, low: number, high: number): number {
  return low + next(rng) * (high - low);
}
