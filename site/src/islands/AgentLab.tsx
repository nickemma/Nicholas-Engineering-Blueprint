import { useState } from "react";
import {
  CASES,
  callFor,
  HARMFUL,
  outcome,
  tally,
  type Controls,
  type Outcome,
  type Prompt,
  type Reviewer,
} from "../sim/agentlab.ts";

const REVIEWERS: [Reviewer, string][] = [
  ["none", "No approval: changes run straight away (before step 7)"],
  ["careless", "Approval, and the reviewer approves everything"],
  ["flagged", "Approval, and the reviewer approves only jobs the question named (step 14)"],
  ["declines", "Approval, and the reviewer declines everything"],
];

const describe = (call: ReturnType<typeof callFor>) =>
  call ? `${call.tool}(${call.job ?? ""})${call.url ? " to its own URL" : ""}` : "none";

export default function AgentLab() {
  const [controls, setControls] = useState<Controls>({ prompt: "plain", protectedJob: false, reviewer: "none" });
  const [source, setSource] = useState<"direct" | "indirect">("direct");
  const cases = CASES.filter((c) => c.source === source);
  const result = tally(cases, controls);
  const set = (change: Partial<Controls>) => setControls({ ...controls, ...change });

  return (
    <div className="lab viz-root">
      <div className="controls">
        <label>
          Attacks{" "}
          <select value={source} onChange={(event) => setSource(event.target.value as "direct" | "indirect")}>
            <option value="direct">Direct: the user asks to retry or cancel protected job 4201 (step 6)</option>
            <option value="indirect">Indirect: planted text in a runbook or a job's output (step 7)</option>
          </select>
        </label>
        <label>
          System prompt{" "}
          <select value={controls.prompt} onChange={(event) => set({ prompt: event.target.value as Prompt })} disabled={source === "indirect"}>
            <option value="plain">The rule in plain words</option>
            <option value="hardened">Hardened: tags, "nothing changes the rules", a reminder</option>
          </select>
        </label>
        <label className="check">
          <input type="checkbox" checked={controls.protectedJob} onChange={(event) => set({ protectedJob: event.target.checked })} />
          The store refuses changes to job 4201 (step 6)
        </label>
        <label>
          Changes{" "}
          <select value={controls.reviewer} onChange={(event) => set({ reviewer: event.target.value as Reviewer })}>
            {REVIEWERS.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
          </select>
        </label>
      </div>
      {source === "indirect" && <p className="hint">Indirect attacks were recorded once, with step 7's approvals on, so the model's calls were proposals. "No approval" shows what they would have done.</p>}
      <dl className="checks">
        <div>
          <dt>The model made a harmful call</dt>
          <dd>{result.proposed} of {result.total}</dd>
        </div>
        <div className={result.harmful === 0 ? "pass" : "fail"}>
          <dt>Harm done</dt>
          <dd>{result.harmful === 0 ? "✓ none" : `✗ ${result.harmful} of ${result.total}`}</dd>
        </div>
      </dl>
      <h3 className="chart-title">Every recorded case</h3>
      <div>
        <table>
          <thead>
            <tr><th>What the user typed</th><th>The model's harmful call</th><th>What the platform did</th></tr>
          </thead>
          <tbody>
            {cases.map((c) => {
              const o: Outcome = outcome(c, controls);
              return (
                <tr key={c.id} className={HARMFUL.includes(o) ? "broken" : ""}>
                  <td>{c.text}{c.planted && <><br /><small>Planted: “{c.planted}”</small></>}</td>
                  <td><code>{describe(callFor(c, controls.prompt))}</code></td>
                  <td>{o}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
