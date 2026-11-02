// Watching a model in production, as in Phase 7, step 11: PSI and KS over the
// training data's deciles, and the kind of drift they can't see.
import { next, rngOf, type Rng } from "./rng.ts";

export const SAMPLE = 5000;
const EPS = 1e-4; // an empty bin can't be allowed to divide by zero

function normal(rng: Rng): number {
  const u = 1 - next(rng);
  const v = next(rng);
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}

export function sample(seed: number, mean: number, spread: number, n = SAMPLE): Float64Array {
  const rng = rngOf(seed);
  return Float64Array.from({ length: n }, () => mean + spread * normal(rng));
}

export interface Reference {
  edges: number[]; // the nine inner decile edges
  shares: number[]; // each of the ten bins' share of the training values
  sorted: Float64Array;
}

function binOf(edges: number[], value: number): number {
  let bin = 0;
  while (bin < edges.length && value > edges[bin]) bin += 1;
  return bin;
}

export function sharesOf(edges: number[], values: Float64Array): number[] {
  const counts = new Array(edges.length + 1).fill(0);
  for (const value of values) counts[binOf(edges, value)] += 1;
  return counts.map((count) => count / values.length);
}

export function reference(training: Float64Array): Reference {
  const sorted = training.slice().sort();
  const edges = Array.from({ length: 9 }, (_, i) => sorted[Math.floor((sorted.length * (i + 1)) / 10)]);
  return { edges, shares: sharesOf(edges, training), sorted };
}

export function psi(expected: number[], actual: number[]): number {
  return expected.reduce((sum, old, i) => {
    const e = Math.max(old, EPS);
    const a = Math.max(actual[i], EPS);
    return sum + (a - e) * Math.log(a / e);
  }, 0);
}

// The largest gap between the two cumulative distributions.
export function ks(a: Float64Array, b: Float64Array): number {
  const x = a.slice().sort();
  const y = b.slice().sort();
  let i = 0;
  let j = 0;
  let gap = 0;
  while (i < x.length && j < y.length) {
    const value = Math.min(x[i], y[j]);
    while (i < x.length && x[i] <= value) i += 1;
    while (j < y.length && y[j] <= value) j += 1;
    gap = Math.max(gap, Math.abs(i / x.length - j / y.length));
  }
  return gap;
}

export type Verdict = "stable" | "moderate" | "major";

export function verdict(value: number): Verdict {
  if (value < 0.1) return "stable";
  return value <= 0.25 ? "moderate" : "major";
}

// A model of y = slope * x, scored by its mean absolute error on live data.
export function meanError(values: Float64Array, modelSlope: number, liveSlope: number): number {
  let total = 0;
  for (const x of values) total += Math.abs(liveSlope * x - modelSlope * x);
  return total / values.length;
}
