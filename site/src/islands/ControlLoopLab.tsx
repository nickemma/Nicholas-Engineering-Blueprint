import { useRef, useState } from "react";
import {
  CAPACITY,
  createCluster,
  drain,
  killPod,
  serving,
  setController,
  setDesired,
  setNodeUp,
  step,
  uncordon,
  type Cluster,
} from "../sim/controlloop.ts";
import { Slider, useTicker } from "./shared.tsx";

export default function ControlLoopLab() {
  const cluster = useRef<Cluster>(createCluster(6));
  const [, render] = useState(0);
  const [running, setRunning] = useState(true);
  const redraw = () => render((count) => count + 1);
  const act = (action: (current: Cluster) => void) => {
    action(cluster.current);
    redraw();
  };
  useTicker(running, 700, () => act(step));

  const state = cluster.current;
  const pending = state.pods.filter((pod) => pod.phase === "pending");
  const live = serving(state);

  return (
    <div className="lab viz-root">
      <div className="controls">
        <Slider label={`Desired Pods: ${state.desired}`} value={state.desired} min={0} max={15} step={1} onChange={(value) => act((current) => setDesired(current, value))} />
        <button type="button" aria-pressed={!state.controllerOn} onClick={() => act((current) => setController(current, !current.controllerOn))}>
          {state.controllerOn ? "Stop the controller" : "Start the controller"}
        </button>
        <button type="button" onClick={() => setRunning(!running)}>{running ? "Pause time" : "Run time"}</button>
        <button type="button" disabled={running} onClick={() => act(step)}>Step 1 s</button>
        <button type="button" onClick={() => { cluster.current = createCluster(6); redraw(); }}>Reset</button>
      </div>
      <dl className="stats">
        <div><dt>Desired</dt><dd>{state.desired}</dd></div>
        <div><dt>Serving</dt><dd>{live}</dd></div>
        <div><dt>Pending, no room</dt><dd>{pending.length}</dd></div>
        <div><dt>Controller</dt><dd>{state.controllerOn ? "running" : "stopped"}</dd></div>
      </dl>
      <div className="nodes">
        {state.nodes.map((node) => {
          const pods = state.pods.filter((pod) => pod.node === node.name);
          const stateName = !node.up ? "down" : node.cordoned ? "cordoned" : "ready";
          return (
            <section key={node.name} className={`node-box ${stateName}`} aria-label={`${node.name}, ${stateName}`}>
              <header><strong>{node.name}</strong><span>{stateName}, {pods.length} of {CAPACITY}</span></header>
              <ul className="pods small">
                {pods.map((pod) => (
                  <li key={pod.id}>
                    <button type="button" className={`pod ${pod.phase} ${node.up ? "" : "lost"}`} aria-label={`Kill Pod ${pod.id}, ${pod.phase}`} onClick={() => act((current) => killPod(current, pod.id))}>
                      <strong>{pod.id}</strong>{node.up ? pod.phase : "unknown"}
                    </button>
                  </li>
                ))}
              </ul>
              <footer>
                <button type="button" onClick={() => act((current) => setNodeUp(current, node.name, !node.up))}>{node.up ? "Take down" : "Bring back"}</button>
                <button type="button" onClick={() => act((current) => (node.cordoned ? uncordon(current, node.name) : drain(current, node.name)))}>{node.cordoned ? "Uncordon" : "Drain"}</button>
              </footer>
            </section>
          );
        })}
      </div>
      {pending.length > 0 && <p className="hint">{pending.length} Pods are Pending: every node that can take one is full.</p>}
      <div className="events">
        <h3>What happened</h3>
        <ol>{state.log.map((line, i) => <li key={`${line}-${i}`}>{line}</li>)}</ol>
      </div>
    </div>
  );
}
