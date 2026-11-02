import { useMemo, useState } from "react";
import { run, type Policy } from "../sim/retrystorm.ts";
import { Choice, LineChart, Slider } from "./shared.tsx";

const percent = (value: number) => `${Math.round(value * 100)}%`;

export default function RetryLab() {
  const [policy, setPolicy] = useState<Policy>("immediate");
  const [load, setLoad] = useState(0.8);
  const [slowdown, setSlowdown] = useState(0.4);
  const result = useMemo(() => run({ policy, load, slowdown }), [policy, load, slowdown]);
  const rows = result.seconds;
  const wasted = rows.reduce((sum, row) => sum + row.wasted, 0);
  const worked = rows.reduce((sum, row) => sum + row.wasted + row.goodput, 0);
  const peak = Math.max(...rows.map((row) => row.offered));
  const yMax = Math.max(1.5, Math.ceil(peak * 2) / 2);

  return (
    <div className="lab viz-root">
      <div className="controls">
        <Choice legend="When a call times out" value={policy} onChange={setPolicy} options={[
          { value: "none", label: "Give up" },
          { value: "immediate", label: "Retry at once" },
          { value: "backoff", label: "Backoff and jitter" },
          { value: "breaker", label: "Those, plus a circuit breaker" },
        ]} />
        <Slider label={`Normal load: ${percent(load)} of capacity`} value={load} min={0.3} max={0.95} step={0.05} onChange={setLoad} />
        <Slider label={`Capacity during the incident: ${percent(slowdown)}`} value={slowdown} min={0.1} max={0.9} step={0.05} onChange={setSlowdown} />
      </div>
      <dl className="stats">
        <div><dt>Back to normal</dt><dd>{result.recoveredAt === null ? "Never, in this run" : `${result.recoveredAt} s after the fix`}</dd></div>
        <div><dt>Peak traffic sent</dt><dd>{percent(peak)} of capacity</dd></div>
        <div><dt>Work wasted on clients who left</dt><dd>{worked === 0 ? "0%" : percent(wasted / worked)}</dd></div>
      </dl>
      <LineChart
        label="Traffic sent to the dependency and answers delivered, over 90 seconds."
        xLabel="Seconds"
        yLabel="Share of healthy capacity"
        xs={rows.map((row) => row.t)}
        series={[
          { name: "Answers delivered", tone: 1, values: rows.map((row) => row.goodput) },
          { name: "Traffic sent", tone: 2, values: rows.map((row) => row.offered) },
        ]}
        yMax={yMax}
        yTicks={[0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4].filter((tick) => tick <= yMax)}
        formatX={(x) => `${Math.round(x)} s`}
        formatY={percent}
        bands={[{ from: 15, to: 35, kind: "incident" }]}
        bandNames={{ incident: "Dependency slow" }}
      />
    </div>
  );
}
