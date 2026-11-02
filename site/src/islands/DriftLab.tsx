import { useMemo, useState } from "react";
import { ks, meanError, psi, reference, sample, sharesOf, verdict, type Reference } from "../sim/drift.ts";
import { Slider } from "./shared.tsx";

const WIDTH = 720;
const HEIGHT = 240;
const MARGIN = { top: 12, right: 12, bottom: 40, left: 48 };
const Y_MAX = 0.5;
const SEED = 2;

const plotWidth = WIDTH - MARGIN.left - MARGIN.right;
const plotHeight = HEIGHT - MARGIN.top - MARGIN.bottom;
const yOf = (share: number) => MARGIN.top + plotHeight * (1 - Math.min(share, Y_MAX) / Y_MAX);
const percent = (value: number) => `${Math.round(value * 100)}%`;

export default function DriftLab() {
  const [mean, setMean] = useState(0);
  const [spread, setSpread] = useState(1);
  const [liveSlope, setLiveSlope] = useState(2);
  const [model, setModel] = useState<{ reference: Reference; slope: number; version: number }>(() => ({
    reference: reference(sample(1, 0, 1)),
    slope: 2,
    version: 1,
  }));
  const [hover, setHover] = useState<number | null>(null);

  const live = useMemo(() => sample(SEED, mean, spread), [mean, spread]);
  const shares = useMemo(() => sharesOf(model.reference.edges, live), [model, live]);
  const value = psi(model.reference.shares, shares);
  const distance = useMemo(() => ks(model.reference.sorted, live), [model, live]);
  const state = verdict(value);
  const error = meanError(live, model.slope, liveSlope);
  const retrain = () => setModel({ reference: reference(live), slope: liveSlope, version: model.version + 1 });
  const barWidth = plotWidth / shares.length;

  return (
    <div className="lab viz-root">
      <div className="controls">
        <Slider label={`Live inputs shift by ${mean.toFixed(1)}`} value={mean} min={-2} max={2} step={0.1} onChange={setMean} />
        <Slider label={`Live spread: ×${spread.toFixed(1)}`} value={spread} min={0.5} max={2} step={0.1} onChange={setSpread} />
        <Slider label={`What's true now: y = ${liveSlope.toFixed(1)}x`} value={liveSlope} min={0} max={4} step={0.1} onChange={setLiveSlope} />
        <button type="button" onClick={retrain}>Retrain on live data</button>
      </div>
      <dl className="stats">
        <div><dt>PSI</dt><dd>{value.toFixed(3)}, {state}</dd></div>
        <div><dt>KS</dt><dd>{distance.toFixed(3)}</dd></div>
        <div><dt>Live error</dt><dd>{error.toFixed(2)}</dd></div>
        <div><dt>Model</dt><dd>version {model.version}: y = {model.slope.toFixed(1)}x</dd></div>
      </dl>
      <ul className="legend" aria-label="Legend">
        <li><span className="swatch block tone-fill-1" aria-hidden="true"></span>Live data's share of each bin</li>
        <li><span className="swatch line muted" aria-hidden="true"></span>Training: 10% in every bin</li>
      </ul>
      <figure className="chart">
        <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} role="img" aria-label={`Live data across the training data's ten deciles. PSI is ${value.toFixed(3)}, ${state}.`}>
          {[0, 0.25, 0.5].map((tick) => (
            <g key={tick}>
              <line className={tick === 0 ? "axis" : "grid"} x1={MARGIN.left} x2={WIDTH - MARGIN.right} y1={yOf(tick)} y2={yOf(tick)} />
              <text className="tick" x={MARGIN.left - 8} y={yOf(tick) + 4} textAnchor="end">{percent(tick)}</text>
            </g>
          ))}
          {shares.map((share, i) => (
            <g key={i} onMouseEnter={() => setHover(i)} onMouseLeave={() => setHover(null)}>
              <rect className="bar" x={MARGIN.left + i * barWidth + 2} width={barWidth - 4} y={yOf(share)} height={Math.max(0, yOf(0) - yOf(share))} rx={4} />
              <rect
                className="hit"
                x={MARGIN.left + i * barWidth}
                width={barWidth}
                y={MARGIN.top}
                height={plotHeight}
                tabIndex={0}
                aria-label={`Decile ${i + 1}: live share ${percent(share)}`}
                onFocus={() => setHover(i)}
                onBlur={() => setHover(null)}
              />
              <text className="tick" x={MARGIN.left + (i + 0.5) * barWidth} y={HEIGHT - MARGIN.bottom + 16} textAnchor="middle">{i + 1}</text>
            </g>
          ))}
          <line className="reference" x1={MARGIN.left} x2={WIDTH - MARGIN.right} y1={yOf(0.1)} y2={yOf(0.1)} />
          <text className="tick" x={MARGIN.left + plotWidth / 2} y={HEIGHT - 4} textAnchor="middle">Training data's deciles</text>
        </svg>
        <p className="tooltip" role="status">{hover === null ? " " : `Decile ${hover + 1}: ${percent(shares[hover])} of live values, against ${percent(model.reference.shares[hover])} in training.`}</p>
      </figure>
    </div>
  );
}
