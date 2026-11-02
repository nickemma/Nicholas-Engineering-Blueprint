import { useEffect, useId, useRef, useState } from "react";

// Calls `tick` on a timer while `running`, unless the reader prefers less motion.
export function useTicker(running: boolean, ms: number, tick: () => void) {
  const latest = useRef(tick);
  latest.current = tick;
  useEffect(() => {
    if (!running || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const timer = setInterval(() => latest.current(), ms);
    return () => clearInterval(timer);
  }, [running, ms]);
}

// Round values for an axis, about six of them.
export function niceTicks(first: number, last: number): number[] {
  const rough = (last - first) / 5;
  const power = 10 ** Math.floor(Math.log10(rough));
  const step = [1, 2, 5, 10].map((multiple) => multiple * power).find((value) => value >= rough)!;
  const ticks: number[] = [];
  for (let tick = Math.ceil(first / step) * step; tick <= last + step * 1e-9; tick += step) {
    ticks.push(Number(tick.toFixed(6)));
  }
  return ticks;
}

export interface Series {
  name: string;
  tone: 1 | 2 | 3;
  values: ArrayLike<number>;
}

export interface Band {
  from: number;
  to: number;
  kind: "incident" | "alarm";
}

interface ChartProps {
  label: string;
  xLabel: string;
  yLabel: string;
  xs: ArrayLike<number>;
  series: Series[];
  yMax: number;
  yTicks: number[];
  formatX: (x: number) => string;
  formatY: (y: number) => string;
  bands?: Band[];
  bandNames?: { incident?: string; alarm?: string };
  height?: number;
}

const WIDTH = 720;
const MARGIN = { top: 12, right: 20, bottom: 46, left: 72 };

export function LineChart(props: ChartProps) {
  const { label, xLabel, yLabel, xs, series, yMax, yTicks, formatX, formatY, bands = [], bandNames, height = 300 } = props;
  const [hover, setHover] = useState<number | null>(null);
  const [table, setTable] = useState(false);
  const plotWidth = WIDTH - MARGIN.left - MARGIN.right;
  const plotHeight = height - MARGIN.top - MARGIN.bottom;
  const first = xs[0];
  const last = xs[xs.length - 1];
  const xOf = (x: number) => MARGIN.left + ((x - first) / (last - first)) * plotWidth;
  const yOf = (y: number) => MARGIN.top + plotHeight * (1 - Math.min(y, yMax) / yMax);
  const count = xs.length;

  const pathOf = (values: ArrayLike<number>) => {
    let path = "";
    for (let i = 0; i < count; i++) path += `${i ? "L" : "M"}${xOf(xs[i]).toFixed(1)} ${yOf(values[i]).toFixed(1)}`;
    return path;
  };

  const onMove = (event: React.MouseEvent<SVGRectElement>) => {
    const box = event.currentTarget.getBoundingClientRect();
    const share = (event.clientX - box.left) / box.width;
    setHover(Math.max(0, Math.min(count - 1, Math.round(share * (count - 1)))));
  };
  const onKey = (event: React.KeyboardEvent) => {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    const stride = Math.max(1, Math.round(count / 40));
    const move = event.key === "ArrowRight" ? stride : -stride;
    setHover((at) => Math.max(0, Math.min(count - 1, (at ?? 0) + move)));
  };

  const xTicks = niceTicks(first, last);
  const rows = Array.from({ length: Math.min(count, 25) }, (_, i) => Math.round((i * (count - 1)) / (Math.min(count, 25) - 1)));
  const kinds = new Set(bands.map((band) => band.kind));

  return (
    <div className="chart-block">
      <ul className="legend" aria-label="Legend">
        {series.length > 1 && series.map((line) => (
          <li key={line.name}><span className={`swatch line tone-${line.tone}`} aria-hidden="true"></span>{line.name}</li>
        ))}
        {kinds.has("incident") && <li><span className="swatch block incident" aria-hidden="true"></span>{bandNames?.incident ?? "Incident"}</li>}
        {kinds.has("alarm") && <li><span className="swatch block alarm" aria-hidden="true"></span>{bandNames?.alarm ?? "Alarm"}</li>}
      </ul>
      <figure className="chart">
        <svg viewBox={`0 0 ${WIDTH} ${height}`} role="img" aria-label={label}>
          {bands.filter((band) => band.kind === "incident").map((band) => (
            <rect key={`i${band.from}`} className="band-incident" x={xOf(band.from)} width={Math.max(1, xOf(band.to) - xOf(band.from))} y={MARGIN.top} height={plotHeight} />
          ))}
          {yTicks.map((tick) => (
            <g key={tick}>
              <line className={tick === 0 ? "axis" : "grid"} x1={MARGIN.left} x2={WIDTH - MARGIN.right} y1={yOf(tick)} y2={yOf(tick)} />
              <text className="tick" x={MARGIN.left - 8} y={yOf(tick) + 4} textAnchor="end">{formatY(tick)}</text>
            </g>
          ))}
          {xTicks.map((tick) => (
            <text key={tick} className="tick" x={xOf(tick)} y={height - MARGIN.bottom + 18} textAnchor={xOf(tick) > WIDTH - MARGIN.right - 24 ? "end" : "middle"}>{formatX(tick)}</text>
          ))}
          <text className="tick" x={MARGIN.left + plotWidth / 2} y={height - 6} textAnchor="middle">{xLabel}</text>
          <text className="tick" transform={`translate(13 ${MARGIN.top + plotHeight / 2}) rotate(-90)`} textAnchor="middle">{yLabel}</text>
          {series.map((line) => <path key={line.name} className={`curve tone-${line.tone}`} d={pathOf(line.values)} />)}
          {bands.filter((band) => band.kind === "alarm").map((band) => (
            <rect key={`a${band.from}`} className="band-alarm" x={xOf(band.from)} width={Math.max(3, xOf(band.to) - xOf(band.from))} y={MARGIN.top + plotHeight - 8} height={8} rx={2} />
          ))}
          {hover !== null && <line className="marker" x1={xOf(xs[hover])} x2={xOf(xs[hover])} y1={MARGIN.top} y2={MARGIN.top + plotHeight} />}
          {hover !== null && series.map((line) => (
            <circle key={line.name} className={`dot tone-${line.tone}`} cx={xOf(xs[hover])} cy={yOf(line.values[hover])} r={4.5} />
          ))}
          <rect
            className="hit"
            x={MARGIN.left}
            y={MARGIN.top}
            width={plotWidth}
            height={plotHeight}
            tabIndex={0}
            aria-label={`${label} Use the left and right arrow keys to read values.`}
            onMouseMove={onMove}
            onMouseLeave={() => setHover(null)}
            onKeyDown={onKey}
            onFocus={() => setHover(0)}
            onBlur={() => setHover(null)}
          />
        </svg>
        <p className="tooltip" role="status">
          {hover === null ? " " : (
            <>
              <strong>{formatX(xs[hover])}</strong>
              {series.map((line) => ` · ${line.name} ${formatY(line.values[hover])}`)}
            </>
          )}
        </p>
      </figure>
      <button type="button" className="link" aria-expanded={table} onClick={() => setTable(!table)}>
        {table ? "Hide the table" : "Show as a table"}
      </button>
      {table && (
        <table>
          <thead><tr><th>{xLabel}</th>{series.map((line) => <th key={line.name}>{line.name}</th>)}</tr></thead>
          <tbody>
            {rows.map((i) => (
              <tr key={i}><td>{formatX(xs[i])}</td>{series.map((line) => <td key={line.name}>{formatY(line.values[i])}</td>)}</tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

export function Slider(props: { label: string; value: number; min: number; max: number; step: number; onChange: (value: number) => void }) {
  const id = useId();
  return (
    <div className="slider">
      <label htmlFor={id}>{props.label}</label>
      <input id={id} type="range" min={props.min} max={props.max} step={props.step} value={props.value} onChange={(event) => props.onChange(Number(event.target.value))} />
    </div>
  );
}

export function Choice<T extends string | number>(props: { legend: string; value: T; options: { value: T; label: string }[]; onChange: (value: T) => void }) {
  const name = useId();
  return (
    <fieldset>
      <legend>{props.legend}</legend>
      {props.options.map((option) => (
        <label key={String(option.value)}>
          <input type="radio" name={name} checked={props.value === option.value} onChange={() => props.onChange(option.value)} />
          {option.label}
        </label>
      ))}
    </fieldset>
  );
}
