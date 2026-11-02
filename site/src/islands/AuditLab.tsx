import { useEffect, useState } from "react";
import {
  chain,
  checkpointOf,
  hex,
  inclusionProof,
  leafHash,
  textBytes,
  verifyChain,
  verifyInclusion,
  witnessAccepts,
  root,
  type Checkpoint,
} from "../sim/audit.ts";

const START = [
  "09:01 alice logged in",
  "09:04 alice read job 12",
  "09:06 bob changed a role",
  "09:07 bob deleted job 12",
  "09:09 alice logged out",
];

const short = (hash: string) => `${hash.slice(0, 12)}…`;

interface Report {
  chainBroken: number | null;
  witnessOk: boolean;
  proofLength: number;
  proofOk: boolean;
  proof: string[];
  root: string;
}

export default function AuditLab() {
  const [records, setRecords] = useState(START);
  const [links, setLinks] = useState<string[]>([]);
  const [checkpoint, setCheckpoint] = useState<Checkpoint | null>(null);
  const [selected, setSelected] = useState(3);
  const [report, setReport] = useState<Report | null>(null);

  useEffect(() => {
    (async () => {
      setLinks(await chain(START));
      setCheckpoint(await checkpointOf(START));
    })();
  }, []);

  useEffect(() => {
    if (!checkpoint || links.length === 0) return;
    let current = true;
    (async () => {
      const leaves = await Promise.all(records.map((record) => leafHash(textBytes(record))));
      const at = Math.min(selected, records.length - 1);
      const tree = await root(leaves);
      const proof = await inclusionProof(leaves, at);
      const next: Report = {
        chainBroken: await verifyChain(records, links),
        witnessOk: await witnessAccepts(records, checkpoint),
        proofLength: proof.length,
        proofOk: await verifyInclusion(leaves[at], at, records.length, proof, tree),
        proof: proof.map(hex),
        root: hex(tree),
      };
      if (current) setReport(next);
    })();
    return () => {
      current = false;
    };
  }, [records, links, checkpoint, selected]);

  const edit = (index: number, text: string) => setRecords(records.map((record, i) => (i === index ? text : record)));
  const rewrite = async () => setLinks(await chain(records));
  const signNow = async () => {
    setLinks(await chain(records));
    setCheckpoint(await checkpointOf(records));
  };
  const append = async () => {
    const added = [...records, `09:${10 + records.length} carol logged in`];
    setRecords(added);
    setLinks(await chain(added));
  };
  const reset = async () => {
    setRecords(START);
    setLinks(await chain(START));
    setCheckpoint(await checkpointOf(START));
    setSelected(3);
  };

  return (
    <div className="lab viz-root">
      <h3 className="chart-title">The log. You're the attacker: change anything.</h3>
      <ol className="records-list">
        {records.map((record, i) => (
          <li key={i} className={report?.chainBroken === i ? "broken" : ""}>
            <input aria-label={`Record ${i}`} value={record} onChange={(event) => edit(i, event.target.value)} />
            <code title={links[i]}>{links[i] ? short(links[i]) : ""}</code>
            <label className="check"><input type="radio" name="proof" checked={selected === i} onChange={() => setSelected(i)} />prove</label>
          </li>
        ))}
      </ol>
      <div className="controls actions">
        <button type="button" onClick={rewrite}>Recompute the whole chain</button>
        <button type="button" onClick={append}>Append a record</button>
        <button type="button" onClick={signNow}>Witness co-signs this state</button>
        <button type="button" onClick={reset}>Reset</button>
      </div>
      {report && checkpoint && (
        <>
          <dl className="checks">
            <div className={report.chainBroken === null ? "pass" : "fail"}>
              <dt>Hash chain</dt>
              <dd>{report.chainBroken === null ? "✓ Verifies" : `✗ Breaks at record ${report.chainBroken}`}</dd>
            </div>
            <div className={report.witnessOk ? "pass" : "fail"}>
              <dt>Witness, holding {checkpoint.size} records' root</dt>
              <dd>{report.witnessOk ? "✓ Same history" : "✗ History was rewritten"}</dd>
            </div>
          </dl>
          <h3 className="chart-title">Inclusion proof for record {Math.min(selected, records.length - 1)}</h3>
          <p className="hint">{report.proofLength} hashes prove this record is in a log of {records.length}, without showing the others. Result: {report.proofOk ? "✓ it's in the tree" : "✗ it isn't"}.</p>
          <ol className="proof">{report.proof.map((hash) => <li key={hash}><code>{short(hash)}</code></li>)}</ol>
          <p className="hint">Root now: <code>{short(report.root)}</code> · witness holds: <code>{short(checkpoint.root)}</code></p>
        </>
      )}
    </div>
  );
}
