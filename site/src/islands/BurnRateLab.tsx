import { useMemo, useState } from "react";
import { BUDGET, MINUTES, RULES, budgetSpent, burnRate, errorSeries, evaluate, naive, type Firing } from "../sim/burnrate.ts";
import { Choice, LineChart, Slider } from "./shared.tsx";

const START = 1440;
const LEAD_IN = 180;

const PRESETS = [
  { value: "outage", label: "Full outage", errorRate: 100, minutes: 10 },
  { value: "partial", label: "Partial failure", errorRate: 2, minutes: 360 },
  { value: "leak", label: "Slow leak", errorRate: 0.4, minutes: 4320 },
  { value: "blip", label: "A small blip", errorRate: 5, minutes: 5 },
];

function duration(minutes: number): string {
  if (minutes < 120) return `${Math.round(minutes)} min`;
  if (minutes < 2880) return `${(minutes / 60).toFixed(minutes < 600 ? 1 : 0)} hours`;
  return `${(minutes / 1440).toFixed(1)} days`;
}

function summary(firings: Firing[]): string {
  if (firings.length === 0) return "Stayed quiet";
  const first = firings[0];
  const after = first.from - START;
  const lasted = firings.reduce((sum, firing) => sum + firing.to - firing.from, 0);
  return `Fired ${duration(after)} in, for ${duration(lasted)}`;
}

export default function BurnRateLab() {
  const [preset, setPreset] = useState("outage");
  const [errorPercent, setError] = useState(100);
  const [minutes, setMinutes] = useState(10);

  const choose = (value: string) => {
    const chosen = PRESETS.find((item) => item.value === value)!;
    setPreset(value);
    setError(chosen.errorRate);
    setMinutes(chosen.minutes);
  };

  const result = useMemo(() => {
    const errors = errorSeries([{ start: START, minutes, errorRate: errorPercent / 100 }]);
    const firings = RULES.map((rule) => ({ rule, firings: evaluate(errors, rule) }));
    const spent = budgetSpent(errors);
    const burn = burnRate(errors);
    // Show the incident and what follows it, so that a short one is visible.
    const from = START - LEAD_IN;
    const to = Math.min(MINUTES, START + minutes + Math.max(360, minutes / 2));
    const stride = Math.max(1, Math.round((to - from) / 400));
    const xs: number[] = [];
    const spentSeries: number[] = [];
    const burnSeries: number[] = [];
    for (let t = from; t < to; t += stride) {
      xs.push((t - START) / 60);
      spentSeries.push(spent[t]);
      burnSeries.push(burn[t]);
    }
    return { firings, naive: naive(errors), spent: spent[MINUTES - 1], xs, spentSeries, burnSeries, end: (to - START) / 60 };
  }, [errorPercent, minutes]);

  const hours = (t: number) => Math.min((t - START) / 60, result.end);
  const incident = { from: 0, to: hours(START + minutes), kind: "incident" as const };
  const alarms = result.firings
    .filter(({ rule }) => rule.severity === "page")
    .flatMap(({ firings }) => firings.map((firing) => ({ from: hours(firing.from), to: hours(firing.to), kind: "alarm" as const })));
  const topBurn = Math.max(...result.burnSeries, 1);
  const yMax = Math.max(20, Math.ceil(topBurn / 20) * 20);
  const budgetMax = Math.max(0.25, Math.ceil(result.spent * 4) / 4);

  return (
    <div className="lab viz-root">
      <div className="controls">
        <Choice legend="Scenario" value={preset} options={PRESETS.map(({ value, label }) => ({ value, label }))} onChange={choose} />
        <Slider label={`Failing requests: ${errorPercent}%`} value={errorPercent} min={0.1} max={100} step={0.1} onChange={(value) => { setPreset(""); setError(value); }} />
        <Slider label={`For ${duration(minutes)}`} value={minutes} min={1} max={4320} step={1} onChange={(value) => { setPreset(""); setMinutes(value); }} />
      </div>
      <dl className="stats">
        <div><dt>Month's budget spent</dt><dd>{(result.spent * 100).toFixed(1)}%</dd></div>
        {result.firings.map(({ rule, firings }) => (
          <div key={rule.name}><dt>{rule.name} alert</dt><dd>{summary(firings)}</dd></div>
        ))}
        <div><dt>A plain 0.1% threshold</dt><dd>{result.naive.length === 0 ? "Stayed quiet" : `Fired ${result.naive.length === 1 ? "once" : `${result.naive.length} times`}`}</dd></div>
      </dl>
      <h3 className="chart-title">Burn rate over the last hour</h3>
      <LineChart
        label="Burn rate around the incident, with the incident and any page marked."
        xLabel="Hours since the incident began"
        yLabel="Burn rate"
        xs={result.xs}
        series={[{ name: "Burn rate", tone: 1, values: result.burnSeries }]}
        yMax={yMax}
        yTicks={[0, yMax / 2, yMax]}
        formatX={(x) => `${Number(x.toFixed(1))} h`}
        formatY={(y) => `${Number(y.toFixed(1))}`}
        bands={[incident, ...alarms]}
        bandNames={{ alarm: "Page firing" }}
        height={230}
      />
      <h3 className="chart-title">Budget spent</h3>
      <LineChart
        label="The share of the month's error budget spent, around the incident."
        xLabel="Hours since the incident began"
        yLabel="Budget spent"
        xs={result.xs}
        series={[{ name: "Budget spent", tone: 2, values: result.spentSeries }]}
        yMax={budgetMax}
        yTicks={[0, budgetMax / 2, budgetMax]}
        formatX={(x) => `${Number(x.toFixed(1))} h`}
        formatY={(y) => `${Number((y * 100).toFixed(1))}%`}
        bands={[incident]}
        height={200}
      />
      <p className="hint">The SLO allows {BUDGET * 100}% of requests to fail over 30 days.</p>
    </div>
  );
}
