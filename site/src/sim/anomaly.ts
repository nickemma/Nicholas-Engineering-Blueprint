// Three of Phase 7, step 12's detectors on one signal, scored against incidents
// injected on a known schedule, so that the right answers exist.
import { exponential, next, rngOf } from "./rng.ts";

export const MINUTES = 720;
export const WARM_UP = 240;
const MAD_TO_SD = 1.4826; // the MAD of a normal distribution is 0.6745 SD
const EWMA_HALFLIFE = 20; // a point this many minutes old counts half
const EWMA_CLIP = 3; // learn from at most this many spreads of change a minute

export type Detector = "threshold" | "mad" | "ewma";

export interface Incident {
  start: number;
  minutes: number;
  name: string;
}

export const INCIDENTS: Incident[] = [
  { start: 290, minutes: 15, name: "A sharp jump" },
  { start: 400, minutes: 60, name: "A slow creep" },
  { start: 540, minutes: 120, name: "A long plateau" },
];

// Latency in ms: a steady base, a slow afternoon rise that isn't an incident,
// noise, and rare harmless spikes.
export function signal(seed: number): Float64Array {
  const rng = rngOf(seed);
  return Float64Array.from({ length: MINUTES }, (_, t) => {
    const busy = t > WARM_UP ? ((t - WARM_UP) / (MINUTES - WARM_UP)) * 12 : 0;
    const noise = (next(rng) + next(rng) + next(rng) - 1.5) * 8;
    const spike = next(rng) < 0.012 ? exponential(rng, 60) : 0;
    let harm = 0;
    const [jump, creep, plateau] = INCIDENTS;
    if (t >= jump.start && t < jump.start + jump.minutes) harm = 70;
    if (t >= creep.start && t < creep.start + creep.minutes) harm = ((t - creep.start) / creep.minutes) * 60;
    if (t >= plateau.start && t < plateau.start + plateau.minutes) harm = 45;
    return 100 + busy + noise + spike + harm;
  });
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = sorted.length >> 1;
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

export function scores(values: Float64Array, detector: Detector): Float64Array {
  const warm = [...values.subarray(0, WARM_UP)];
  if (detector === "threshold") {
    const mean = warm.reduce((sum, value) => sum + value, 0) / warm.length;
    const sd = Math.sqrt(warm.reduce((sum, value) => sum + (value - mean) ** 2, 0) / warm.length);
    return values.map((value) => Math.abs(value - mean) / sd);
  }
  if (detector === "mad") {
    const centre = median(warm);
    const mad = median(warm.map((value) => Math.abs(value - centre))) * MAD_TO_SD;
    return values.map((value) => Math.abs(value - centre) / mad);
  }
  // EWMA keeps learning, so its baseline follows whatever it's shown. Unclipped,
  // one huge value inflates the variance so much that the next looks normal,
  // and an alarm that needs two in a row never comes.
  const alpha = 1 - 0.5 ** (1 / EWMA_HALFLIFE);
  let mean = warm.reduce((sum, value) => sum + value, 0) / warm.length;
  let variance = warm.reduce((sum, value) => sum + (value - mean) ** 2, 0) / warm.length;
  return values.map((value) => {
    const scale = Math.sqrt(variance);
    const score = Math.abs(value - mean) / scale;
    const gap = Math.max(-EWMA_CLIP * scale, Math.min(EWMA_CLIP * scale, value - mean));
    mean += alpha * gap;
    variance = (1 - alpha) * (variance + alpha * gap * gap);
    return score;
  });
}

export interface Alarm {
  from: number;
  to: number;
}

// Above the threshold for `need` minutes in a row is an alarm. Nothing can fire
// during the warm-up.
export function alarms(scored: Float64Array, threshold: number, need: number): Alarm[] {
  const found: Alarm[] = [];
  let run = 0;
  scored.forEach((score, t) => {
    run = t >= WARM_UP && score > threshold ? run + 1 : 0;
    if (run < need) return;
    const last = found.at(-1);
    if (last && last.to === t) last.to = t + 1;
    else found.push({ from: t, to: t + 1 });
  });
  return found;
}

export interface Score {
  found: number;
  recall: number;
  precision: number; // 0 when there were no alarms at all
  falseAlarms: number;
  meanDetect: number | null; // minutes from an incident's start to its first alarm
  covered: number; // the share of incident minutes under an alarm
}

export function evaluate(found: Alarm[], incidents: Incident[]): Score {
  const hits = (alarm: Alarm, incident: Incident) =>
    alarm.from < incident.start + incident.minutes && alarm.to > incident.start;
  const detected = incidents
    .map((incident) => found.filter((alarm) => hits(alarm, incident)).map((alarm) => Math.max(alarm.from, incident.start) - incident.start))
    .filter((delays) => delays.length > 0);
  const real = found.filter((alarm) => incidents.some((incident) => hits(alarm, incident))).length;
  const total = incidents.reduce((sum, incident) => sum + incident.minutes, 0);
  let covered = 0;
  for (const incident of incidents) {
    for (let t = incident.start; t < incident.start + incident.minutes; t++) {
      if (found.some((alarm) => t >= alarm.from && t < alarm.to)) covered += 1;
    }
  }
  return {
    found: detected.length,
    recall: detected.length / incidents.length,
    precision: found.length === 0 ? 0 : real / found.length,
    falseAlarms: found.length - real,
    meanDetect: detected.length === 0 ? null : detected.reduce((sum, delays) => sum + Math.min(...delays), 0) / detected.length,
    covered: covered / total,
  };
}
