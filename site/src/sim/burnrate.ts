// Multi-window, multi-burn-rate alerts over a week, one sample a minute, with
// the same rules as Phase 5, step 10: an SLO of 99.9% over 30 days.

export const BUDGET = 0.001;
export const MINUTES = 7 * 24 * 60;
export const MONTH = 30 * 24 * 60;

export interface Incident {
  start: number; // minutes
  minutes: number;
  errorRate: number;
}

export interface Rule {
  name: string;
  severity: "page" | "ticket";
  conditions: { long: number; short: number; burn: number }[];
  forMinutes: number;
}

export const RULES: Rule[] = [
  {
    name: "Page",
    severity: "page",
    conditions: [
      { long: 60, short: 5, burn: 14.4 },
      { long: 360, short: 30, burn: 6 },
    ],
    forMinutes: 2,
  },
  {
    name: "Ticket",
    severity: "ticket",
    conditions: [
      { long: 1440, short: 120, burn: 3 },
      { long: 4320, short: 360, burn: 1 },
    ],
    forMinutes: 60,
  },
];

export function errorSeries(incidents: Incident[]): Float64Array {
  const errors = new Float64Array(MINUTES);
  for (const { start, minutes, errorRate } of incidents) {
    for (let t = start; t < Math.min(start + minutes, MINUTES); t++) errors[t] = errorRate;
  }
  return errors;
}

// Mean error rate over the last `window` minutes, ending at each minute, from
// running totals. Prometheus's rate() also looks only at the window it's given,
// so a young window sees fewer than `window` minutes of errors, and zeros
// before that.
export function windowed(errors: Float64Array, window: number): Float64Array {
  const totals = new Float64Array(errors.length + 1);
  errors.forEach((error, t) => (totals[t + 1] = totals[t] + error));
  return errors.map((_, t) => (totals[t + 1] - totals[Math.max(0, t + 1 - window)]) / window);
}

export interface Firing {
  rule: string;
  severity: Rule["severity"];
  from: number;
  to: number; // the first minute it had stopped
}

export function evaluate(errors: Float64Array, rule: Rule): Firing[] {
  const windows = new Map<number, Float64Array>();
  const over = (window: number) => {
    if (!windows.has(window)) windows.set(window, windowed(errors, window));
    return windows.get(window)!;
  };
  const firings: Firing[] = [];
  let held = 0;
  for (let t = 0; t < errors.length; t++) {
    const pending = rule.conditions.some(({ long, short, burn }) => {
      const limit = burn * BUDGET;
      return over(long)[t] > limit && over(short)[t] > limit;
    });
    held = pending ? held + 1 : 0;
    const last = firings.at(-1);
    if (held > rule.forMinutes) {
      if (last && last.to === t) last.to = t + 1;
      else firings.push({ rule: rule.name, severity: rule.severity, from: t, to: t + 1 });
    }
  }
  return firings;
}

// A plain threshold, for comparison: more than 0.1% errors over five minutes.
export function naive(errors: Float64Array): Firing[] {
  const short = windowed(errors, 5);
  const firings: Firing[] = [];
  short.forEach((value, t) => {
    if (value <= BUDGET) return;
    const last = firings.at(-1);
    if (last && last.to === t) last.to = t + 1;
    else firings.push({ rule: "Naive", severity: "page", from: t, to: t + 1 });
  });
  return firings;
}

// The share of the month's budget gone by each minute.
export function budgetSpent(errors: Float64Array): Float64Array {
  let spent = 0;
  return errors.map((error) => {
    spent += error / (BUDGET * MONTH);
    return spent;
  });
}

export function burnRate(errors: Float64Array, window = 60): Float64Array {
  return windowed(errors, window).map((value) => value / BUDGET);
}
