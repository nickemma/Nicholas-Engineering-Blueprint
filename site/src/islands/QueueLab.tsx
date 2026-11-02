import { useMemo, useState } from "react";
import { meanWait, simulate, type Cv2 } from "../sim/queue.ts";

const CHOICES: { cv2: Cv2; label: string; note: string }[] = [
  { cv2: 0, label: "Identical", note: "every job takes exactly the same time" },
  { cv2: 0.5, label: "Steady", note: "jobs vary a little" },
  { cv2: 1, label: "Random", note: "exponential job times" },
  { cv2: 4, label: "Spiky", note: "mostly short jobs, with a few long ones" },
];

const LOADS = Array.from({ length: 18 }, (_, i) => Math.round((0.05 + i * 0.05) * 100) / 100);
const JOBS = 60_000;
const Y_MAX = 30;

const WIDTH = 720;
const HEIGHT = 380;
const MARGIN = { top: 16, right: 24, bottom: 48, left: 56 };
const plotWidth = WIDTH - MARGIN.left - MARGIN.right;
const plotHeight = HEIGHT - MARGIN.top - MARGIN.bottom;
const xOf = (rho: number) => MARGIN.left + rho * plotWidth;
const yOf = (wait: number) => MARGIN.top + plotHeight * (1 - Math.min(wait, Y_MAX) / Y_MAX);

const format = (value: number) => (value >= 10 ? value.toFixed(0) : value.toFixed(1));

export default function QueueLab() {
  const [cv2, setCv2] = useState<Cv2>(1);
  const [rho, setRho] = useState(0.7);
  const [hover, setHover] = useState<number | null>(null);
  const [table, setTable] = useState(false);

  const points = useMemo(() => LOADS.map((load) => simulate(load, cv2, JOBS, 11)), [cv2]);
  const curve = useMemo(() => {
    const path: string[] = [];
    for (let load = 0.01; load <= 0.985; load += 0.005) {
      const wait = meanWait(load, cv2);
      if (wait > Y_MAX) break;
      path.push(`${path.length ? "L" : "M"}${xOf(load).toFixed(1)} ${yOf(wait).toFixed(1)}`);
    }
    return path.join(" ");
  }, [cv2]);
  const selected = useMemo(() => simulate(rho, cv2, JOBS * 3, 13), [rho, cv2]);
  const predicted = meanWait(rho, cv2);
  const hovered = hover === null ? null : points[hover];

  return (
    <div className="lab viz-root">
      <div className="controls">
        <fieldset>
          <legend>How much do jobs vary?</legend>
          {CHOICES.map((choice) => (
            <label key={choice.cv2}>
              <input type="radio" name="cv2" checked={cv2 === choice.cv2} onChange={() => setCv2(choice.cv2)} />
              {choice.label}
            </label>
          ))}
          <p className="hint">{CHOICES.find((choice) => choice.cv2 === cv2)?.note}</p>
        </fieldset>
        <label className="slider">
          Load: {Math.round(rho * 100)}% busy
          <input type="range" min={0.1} max={0.95} step={0.01} value={rho} onChange={(event) => setRho(Number(event.target.value))} />
        </label>
      </div>

      <dl className="stats">
        <div><dt>Mean wait, predicted</dt><dd>{format(predicted)} job lengths</dd></div>
        <div><dt>Mean wait, simulated</dt><dd>{format(selected.meanWait)} job lengths</dd></div>
        <div><dt>Unlucky jobs (95th percentile)</dt><dd>{format(selected.p95Wait)} job lengths</dd></div>
      </dl>

      <ul className="legend" aria-label="Legend">
        <li><span className="swatch line" aria-hidden="true"></span>Formula (Pollaczek-Khinchine)</li>
        <li><span className="swatch dot" aria-hidden="true"></span>Simulated in your browser</li>
      </ul>

      <figure className="chart">
        <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} role="img" aria-label={`Mean wait against load for ${CHOICES.find((c) => c.cv2 === cv2)?.label} jobs: the wait stays low, then rises steeply near full load.`}>
          {[0, 10, 20, 30].map((tick) => (
            <g key={tick}>
              <line className={tick === 0 ? "axis" : "grid"} x1={MARGIN.left} x2={WIDTH - MARGIN.right} y1={yOf(tick)} y2={yOf(tick)} />
              <text className="tick" x={MARGIN.left - 8} y={yOf(tick) + 4} textAnchor="end">{tick}</text>
            </g>
          ))}
          {[0, 0.25, 0.5, 0.75, 1].map((tick) => (
            <text key={tick} className="tick" x={xOf(tick)} y={HEIGHT - MARGIN.bottom + 20} textAnchor="middle">{tick * 100}%</text>
          ))}
          <text className="tick" x={MARGIN.left + plotWidth / 2} y={HEIGHT - 8} textAnchor="middle">How busy the server is</text>
          <text className="tick" transform={`translate(14 ${MARGIN.top + plotHeight / 2}) rotate(-90)`} textAnchor="middle">Mean wait, in job lengths</text>

          <line className="marker" x1={xOf(rho)} x2={xOf(rho)} y1={MARGIN.top} y2={HEIGHT - MARGIN.bottom} />
          <path className="curve" d={curve} />
          {points.map((point) => point.meanWait <= Y_MAX && (
            <circle key={point.rho} className="point" cx={xOf(point.rho)} cy={yOf(point.meanWait)} r={5} />
          ))}
          {points.map((point, i) => (
            <rect
              key={point.rho}
              className="hit"
              x={xOf(point.rho) - 18}
              width={36}
              y={MARGIN.top}
              height={plotHeight}
              tabIndex={0}
              aria-label={`Load ${Math.round(point.rho * 100)}%: simulated wait ${format(point.meanWait)}`}
              onMouseEnter={() => setHover(i)}
              onMouseLeave={() => setHover(null)}
              onFocus={() => setHover(i)}
              onBlur={() => setHover(null)}
            />
          ))}
          {hovered && hovered.meanWait <= Y_MAX && <circle className="focus" cx={xOf(hovered.rho)} cy={yOf(hovered.meanWait)} r={8} />}
        </svg>
        {hovered && (
          <p className="tooltip" role="status">
            <strong>{Math.round(hovered.rho * 100)}% busy.</strong> Formula {format(meanWait(hovered.rho, cv2))}, simulated {format(hovered.meanWait)}, 95th percentile {format(hovered.p95Wait)}.
          </p>
        )}
      </figure>

      <button type="button" className="link" aria-expanded={table} onClick={() => setTable(!table)}>
        {table ? "Hide the table" : "Show the numbers as a table"}
      </button>
      {table && (
        <table>
          <thead>
            <tr><th>Load</th><th>Formula</th><th>Simulated</th><th>95th percentile</th></tr>
          </thead>
          <tbody>
            {points.map((point) => (
              <tr key={point.rho}>
                <td>{Math.round(point.rho * 100)}%</td>
                <td>{format(meanWait(point.rho, cv2))}</td>
                <td>{format(point.meanWait)}</td>
                <td>{format(point.p95Wait)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
