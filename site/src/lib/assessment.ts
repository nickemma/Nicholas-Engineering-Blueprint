import type { Stop } from "./journey.ts";

export const LEVELS = [
  { id: "junior", title: "Junior", focus: "Deliver a bounded change", description: "Small independent tickets, correctness and isolation checks, clear documentation, then review and correction.", anchor: "junior-bounded-independent-tickets" },
  { id: "intermediate", title: "Intermediate", focus: "Own a safe service change", description: "Investigate unfamiliar code, agree the contract, prove compatibility, measure capacity and demonstrate rollback.", anchor: "intermediate-investigate-change-and-operate" },
  { id: "senior", title: "Senior", focus: "Defend and coordinate the decision", description: "Negotiate scope, compare cost and reliability, sequence work across owners and help another contributor deliver.", anchor: "senior-decide-coordinate-and-review" },
] as const;
export type Level = (typeof LEVELS)[number]["id"];
export const isLevel = (value: unknown): value is Level => LEVELS.some((level) => level.id === value);

// Phases come from JOURNEY; bridge/capstone entries do not have phase assessments.
export function assessmentPhases(stops: Stop[]) {
  return stops.filter((stop) => /^\/lessons\/0\d-/.test(stop.url));
}

export function assessmentUrl(stop: Stop, level: Level) {
  return `${stop.url}assessment/#${LEVELS.find((item) => item.id === level)!.anchor}`;
}
