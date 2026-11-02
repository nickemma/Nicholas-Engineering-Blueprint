import { useMemo, useState } from "react";
import { INCIDENTS, MINUTES, WARM_UP, alarms, evaluate, scores, signal, type Detector } from "../sim/anomaly.ts";
import { Choice, LineChart, Slider } from "./shared.tsx";

const percent = (value: number) => `${Math.round(value * 100)}%`;
const XS = Array.from({ length: MINUTES }, (_, t) => t);

export default function AnomalyLab() {
  const [detector, setDetector] = useState<Detector>("threshold");
  const [threshold, setThreshold] = useState(5);
  const [need, setNeed] = useState(2);
  const [seed, setSeed] = useState(3);

  const values = useMemo(() => signal(seed), [seed]);
  const scored = useMemo(() => scores(values, detector), [values, detector]);
  const found = useMemo(() => alarms(scored, threshold, need), [scored, threshold, need]);
  const score = useMemo(() => evaluate(found, INCIDENTS), [found]);
  const perIncident = INCIDENTS.map((incident) => {
    const first = found.find((alarm) => alarm.from < incident.start + incident.minutes && alarm.to > incident.start);
    return { incident, delay: first ? Math.max(first.from, incident.start) - incident.start : null };
  });

  return (
    <div className="lab viz-root">
      <div className="controls">
        <Choice legend="Detector" value={detector} onChange={setDetector} options={[
          { value: "threshold", label: "Mean and SD" },
          { value: "mad", label: "Median and MAD" },
          { value: "ewma", label: "EWMA" },
        ]} />
        <Slider label={`Alarm above a score of ${threshold.toFixed(1)}`} value={threshold} min={1.5} max={12} step={0.5} onChange={setThreshold} />
        <Slider label={`For ${need} ${need === 1 ? "minute" : "minutes"} in a row`} value={need} min={1} max={6} step={1} onChange={setNeed} />
        <button type="button" onClick={() => setSeed(seed + 1)}>Another day</button>
      </div>
      <dl className="stats">
        <div><dt>Recall</dt><dd>{score.found} of {INCIDENTS.length} incidents</dd></div>
        <div><dt>Precision</dt><dd>{found.length === 0 ? "no alarms" : percent(score.precision)}</dd></div>
        <div><dt>False alarms</dt><dd>{score.falseAlarms}</dd></div>
        <div><dt>Mean time to detect</dt><dd>{score.meanDetect === null ? "n/a" : `${score.meanDetect.toFixed(0)} min`}</dd></div>
        <div><dt>Incident time under alarm</dt><dd>{percent(score.covered)}</dd></div>
      </dl>
      <LineChart
        label="Latency over twelve hours, with incidents and alarms marked."
        xLabel="Minutes"
        yLabel="Latency, ms"
        xs={XS}
        series={[{ name: "Latency", tone: 1, values }]}
        yMax={240}
        yTicks={[0, 80, 160, 240]}
        formatX={(x) => `${Math.round(x)} min`}
        formatY={(y) => `${Math.round(y)}`}
        bands={[
          ...INCIDENTS.map((incident) => ({ from: incident.start, to: incident.start + incident.minutes, kind: "incident" as const })),
          ...found.map((alarm) => ({ ...alarm, kind: "alarm" as const })),
        ]}
      />
      <ul className="incident-list">
        {perIncident.map(({ incident, delay }) => (
          <li key={incident.name}>
            {delay === null ? "✗" : "✓"} {incident.name}, {incident.minutes} minutes: {delay === null ? "missed" : `found after ${delay} min`}
          </li>
        ))}
      </ul>
      <p className="hint">The first {WARM_UP} minutes are the quiet warm-up that teaches the detectors what normal looks like.</p>
    </div>
  );
}
