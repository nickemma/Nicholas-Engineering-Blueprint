import { useEffect, useRef, useState } from "react";
import {
  advance,
  CLUSTER,
  crash,
  createSim,
  currentLeader,
  MAJORITY,
  nameOf,
  restart,
  setSplit,
  type Sim,
} from "../sim/raft.ts";

const SIZE = 420;
const CENTRE = SIZE / 2;
const RING = 150;
const RADIUS = 36;
const SPEEDS = [
  { label: "Slow", rate: 0.05 },
  { label: "Normal", rate: 0.15 },
  { label: "Fast", rate: 0.5 },
];

function position(id: number) {
  const angle = (id / CLUSTER) * 2 * Math.PI - Math.PI / 2;
  return { x: CENTRE + RING * Math.cos(angle), y: CENTRE + RING * Math.sin(angle) };
}

export default function RaftLab() {
  const sim = useRef<Sim>(createSim(42));
  const [, render] = useState(0);
  const [running, setRunning] = useState(false);
  const [speed, setSpeed] = useState(SPEEDS[1].rate);

  useEffect(() => {
    if (!matchMedia("(prefers-reduced-motion: reduce)").matches) setRunning(true);
  }, []);

  useEffect(() => {
    if (!running) return;
    let frame = 0;
    let last = performance.now();
    const tick = (now: number) => {
      advance(sim.current, sim.current.now + Math.min(now - last, 100) * speed);
      last = now;
      render((count) => count + 1);
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [running, speed]);

  const change = (action: (current: Sim) => void) => {
    action(sim.current);
    render((count) => count + 1);
  };
  const reset = (randomised: boolean) => {
    sim.current = createSim(42, randomised);
    render((count) => count + 1);
  };

  const state = sim.current;
  const leader = currentLeader(state);
  const highestTerm = Math.max(...state.nodes.map((node) => node.term));
  const alive = state.nodes.filter((node) => node.alive).length;

  return (
    <div className="lab raft viz-root">
      <div className="controls">
        <button type="button" onClick={() => setRunning(!running)}>{running ? "Pause" : "Run"}</button>
        <button type="button" disabled={running} onClick={() => change((current) => advance(current, current.now + 10))}>Step 10 ms</button>
        <fieldset>
          <legend>Speed</legend>
          {SPEEDS.map((choice) => (
            <label key={choice.label}>
              <input type="radio" name="speed" checked={speed === choice.rate} onChange={() => setSpeed(choice.rate)} />
              {choice.label}
            </label>
          ))}
        </fieldset>
        <button type="button" aria-pressed={state.split} onClick={() => change((current) => setSplit(current, !current.split))}>
          {state.split ? "Heal the network" : "Split the network"}
        </button>
        <button type="button" onClick={() => reset(!state.randomised)}>
          {state.randomised ? "Try identical timeouts" : "Back to random timeouts"}
        </button>
        <button type="button" onClick={() => reset(state.randomised)}>Reset</button>
      </div>

      <dl className="stats">
        <div><dt>Leader</dt><dd>{leader ? nameOf(leader.id) : "none"}</dd></div>
        <div><dt>Highest term</dt><dd>{highestTerm}</dd></div>
        <div><dt>Nodes up</dt><dd>{alive} of {CLUSTER}, {MAJORITY} needed</dd></div>
      </dl>

      <div className="raft-body">
        <svg viewBox={`0 0 ${SIZE} ${SIZE}`} role="group" aria-label="A cluster of five nodes in a ring. Choose a node to crash or restart it.">
          {state.split && <line className="split" x1={CENTRE + 30} y1={8} x2={CENTRE - 60} y2={SIZE - 8} />}
          {state.messages.map((message, i) => {
            const from = position(message.from);
            const to = position(message.to);
            const progress = Math.min(1, (state.now - message.sentAt) / (message.deliverAt - message.sentAt));
            return (
              <circle
                key={i}
                className={`message ${message.type}${message.granted ? " granted" : ""}`}
                cx={from.x + (to.x - from.x) * progress}
                cy={from.y + (to.y - from.y) * progress}
                r={5}
              />
            );
          })}
          {state.nodes.map((node) => {
            const { x, y } = position(node.id);
            const span = node.deadline - node.startedWaiting;
            const left = Number.isFinite(span) ? Math.max(0, (node.deadline - state.now) / span) : 0;
            const circumference = 2 * Math.PI * (RADIUS + 6);
            const stateName = !node.alive ? "crashed" : node.role;
            return (
              <g key={node.id}>
                {node.alive && node.role !== "leader" && (
                  <circle
                    className="timer"
                    cx={x}
                    cy={y}
                    r={RADIUS + 6}
                    strokeDasharray={`${left * circumference} ${circumference}`}
                    transform={`rotate(-90 ${x} ${y})`}
                  />
                )}
                <circle className={`node ${stateName}`} cx={x} cy={y} r={RADIUS} />
                <text className="node-name" x={x} y={y - 6} textAnchor="middle">{nameOf(node.id)}</text>
                <text className="node-role" x={x} y={y + 10} textAnchor="middle">{stateName}</text>
                <text className="node-role" x={x} y={y + 23} textAnchor="middle">term {node.term}</text>
                <foreignObject x={x - RADIUS} y={y - RADIUS} width={RADIUS * 2} height={RADIUS * 2}>
                  <button
                    type="button"
                    className="node-hit"
                    aria-label={node.alive ? `Crash node ${nameOf(node.id)}, ${stateName} in term ${node.term}` : `Restart node ${nameOf(node.id)}`}
                    onClick={() => change((current) => (node.alive ? crash(current, node.id) : restart(current, node.id)))}
                  />
                </foreignObject>
              </g>
            );
          })}
        </svg>
        <div className="events">
          <h3>What happened</h3>
          <ol aria-live="off">
            {state.events.map((event, i) => (
              <li key={`${event.at}-${i}`}><span>{Math.round(event.at)} ms</span>{event.text}</li>
            ))}
          </ol>
        </div>
      </div>
      <ul className="legend" aria-label="Legend">
        <li><span className="swatch msg-vote" aria-hidden="true"></span>Vote request</li>
        <li><span className="swatch msg-granted" aria-hidden="true"></span>Vote granted</li>
        <li><span className="swatch msg-beat" aria-hidden="true"></span>Heartbeat</li>
        <li>The ring round a node is its election timer, running out</li>
      </ul>
      {state.violations.length > 0 && <p className="alert">Safety violated: {state.violations[0]}</p>}
    </div>
  );
}
