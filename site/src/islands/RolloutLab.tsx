import { useState } from "react";
import { createRollout, deploy, isComplete, isStalled, rollBack, step, type Bug, type Rollout } from "../sim/rollout.ts";
import { Choice, LineChart, useTicker } from "./shared.tsx";

const percent = (value: number) => `${Math.round(value * 100)}%`;

export default function RolloutLab() {
  const [maxSurge, setSurge] = useState(1);
  const [maxUnavailable, setUnavailable] = useState(0);
  const [bug, setBug] = useState<Bug>("errors");
  const [deepProbe, setDeep] = useState(false);
  const valid = maxSurge + maxUnavailable > 0;
  const fresh = () => createRollout({ desired: 4, maxSurge, maxUnavailable, bug, deepProbe });
  const [rollout, setRollout] = useState<Rollout>(() => fresh());
  const [running, setRunning] = useState(false);
  const [, render] = useState(0);

  const advance = () => {
    step(rollout);
    if (isComplete(rollout) || rollout.tick > 120) setRunning(false);
    render((count) => count + 1);
  };
  useTicker(running, 500, advance);

  const start = () => {
    const next = fresh();
    deploy(next);
    setRollout(next);
    setRunning(true);
  };
  const back = () => {
    rollBack(rollout);
    setRunning(true);
    render((count) => count + 1);
  };

  const done = isComplete(rollout);
  const stalled = isStalled(rollout);
  const latest = rollout.history.at(-1)!;
  const worst = Math.min(...rollout.history.map((sample) => sample.served));
  const status = rollout.tick === 0
    ? "Version 1 is serving. Choose a release and deploy it."
    : stalled
      ? "Stalled. Kubernetes reports it and stops there: rolling back is your decision."
      : done
        ? `Finished: every Pod runs version ${rollout.target}.`
        : `Rolling to version ${rollout.target}...`;

  return (
    <div className="lab viz-root">
      <div className="controls">
        <Choice legend="What's wrong with version 2?" value={bug} onChange={setBug} options={[
          { value: "none", label: "Nothing" },
          { value: "crash", label: "Crashes at start" },
          { value: "errors", label: "Starts, then fails requests" },
        ]} />
        <Choice legend="maxSurge" value={maxSurge} onChange={setSurge} options={[0, 1, 2].map((value) => ({ value, label: String(value) }))} />
        <Choice legend="maxUnavailable" value={maxUnavailable} onChange={setUnavailable} options={[0, 1, 2].map((value) => ({ value, label: String(value) }))} />
        <label className="check">
          <input type="checkbox" checked={deepProbe} onChange={(event) => setDeep(event.target.checked)} />
          Readiness checks what clients need, not just that the port answers
        </label>
        {!valid && <p className="hint">Both at 0 means nothing can move, and Kubernetes rejects it.</p>}
      </div>
      <div className="controls actions">
        <button type="button" disabled={!valid} onClick={start}>Deploy version 2</button>
        <button type="button" disabled={rollout.tick === 0 || rollout.target === 1} onClick={back}>Roll back</button>
        <button type="button" disabled={running || rollout.tick === 0} onClick={advance}>Step 1 s</button>
      </div>

      <p className="status" role="status">{status}</p>
      <ul className="pods" aria-label="Pods">
        {rollout.pods.map((pod) => (
          <li key={pod.id} className={`pod v${pod.version} ${pod.phase}`}>
            <strong>v{pod.version}</strong>{pod.phase}
          </li>
        ))}
      </ul>
      <dl className="stats">
        <div><dt>Serving now</dt><dd>{latest.ready} of {rollout.desired}</dd></div>
        <div><dt>Requests failing now</dt><dd>{percent(latest.errorRate)}</dd></div>
        <div><dt>Worst moment for users</dt><dd>{percent(worst)} served</dd></div>
      </dl>
      {rollout.history.length > 1 && (
        <LineChart
          label="The share of normal traffic answered well, over time."
          xLabel="Seconds"
          yLabel="Traffic served well"
          xs={rollout.history.map((sample) => sample.tick)}
          series={[{ name: "Served well", tone: 1, values: rollout.history.map((sample) => sample.served) }]}
          yMax={1}
          yTicks={[0, 0.25, 0.5, 0.75, 1]}
          formatX={(x) => `${Math.round(x)} s`}
          formatY={percent}
          height={240}
        />
      )}
    </div>
  );
}
