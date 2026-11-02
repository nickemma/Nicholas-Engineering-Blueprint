import { useState } from "react";
import { createLog, flipByte, fsync, powerCut, recover, write, HEADER_LEN, type LogFile, type Recovery } from "../sim/tornlog.ts";
import { Slider } from "./shared.tsx";

const WORDS = ["paid 100", "paid 250", "refund 40", "paid 75", "refund 10"];

// Which part of a record each byte belongs to, walking the headers while they
// make sense.
function partsOf(data: Uint8Array): string[] {
  const parts: string[] = [];
  let at = 0;
  while (at < data.length) {
    const length = at + 4 <= data.length ? data[at] | (data[at + 1] << 8) : 0;
    const end = at + HEADER_LEN + length;
    for (let i = at; i < Math.min(end, data.length); i++) {
      parts.push(i - at < 4 ? "length" : i - at < HEADER_LEN ? "checksum" : "payload");
    }
    if (end <= at) break;
    at = end;
  }
  return parts;
}

function Bytes({ data, part, onFlip, label }: { data: Uint8Array; part?: string; onFlip?: (at: number) => void; label: string }) {
  if (data.length === 0) return <p className="hint">{label}: empty</p>;
  const parts = partsOf(data);
  return (
    <div className="bytes-block">
      <p className="hint">{label}: {data.length} bytes</p>
      <ol className="bytes">
        {[...data].map((byte, i) => (
          <li key={i}>
            {onFlip ? (
              <button type="button" className={parts[i]} aria-label={`Damage byte ${i}, ${parts[i]}`} onClick={() => onFlip(i)}>{byte.toString(16).padStart(2, "0")}</button>
            ) : (
              <span className={part ?? parts[i]}>{byte.toString(16).padStart(2, "0")}</span>
            )}
          </li>
        ))}
      </ol>
    </div>
  );
}

export default function DiskLab() {
  const [log, setLog] = useState<LogFile>(() => createLog());
  const [next, setNext] = useState(0);
  const [reached, setReached] = useState(0);
  const [disk, setDisk] = useState<Uint8Array | null>(null);
  const [result, setResult] = useState<Recovery | null>(null);

  const add = () => {
    setLog(write(log, WORDS[next % WORDS.length]));
    setNext(next + 1);
  };
  const cut = () => {
    setDisk(powerCut(log, Math.min(reached, log.cached.length)));
    setResult(null);
  };
  const reset = () => {
    setLog(createLog());
    setNext(0);
    setReached(0);
    setDisk(null);
    setResult(null);
  };
  const flip = (at: number) => {
    setDisk(flipByte(disk!, at));
    setResult(null);
  };

  const lost = result?.status === "ok" ? log.acknowledged.length - result.records.length : 0;

  return (
    <div className="lab viz-root">
      {disk === null ? (
        <>
          <div className="controls actions">
            <button type="button" onClick={add}>Write a record</button>
            <button type="button" disabled={log.cached.length === 0} onClick={() => { setLog(fsync(log)); setReached(0); }}>fsync</button>
            <button type="button" onClick={reset}>Start again</button>
          </div>
          <dl className="stats">
            <div><dt>Writes the program reported done</dt><dd>{log.acknowledged.length}</dd></div>
            <div><dt>Covered by fsync</dt><dd>{log.synced}</dd></div>
          </dl>
          <Bytes data={log.durable} label="On the disk" />
          <Bytes data={log.cached} part="cached" label="In the page cache, in memory" />
          <div className="controls">
            <Slider label={`When the power fails, ${Math.min(reached, log.cached.length)} of the ${log.cached.length} unsynced bytes have reached the disk`} value={Math.min(reached, log.cached.length)} min={0} max={log.cached.length} step={1} onChange={setReached} />
            <button type="button" className="danger" disabled={log.acknowledged.length === 0} onClick={cut}>Cut the power</button>
          </div>
        </>
      ) : (
        <>
          <div className="controls actions">
            <button type="button" onClick={() => setResult(recover(disk))}>Reopen the log</button>
            <button type="button" onClick={reset}>Start again</button>
          </div>
          <Bytes data={disk} label="The disk after the crash. Select a byte to damage it, as a failing disk might" onFlip={flip} />
          <ul className="legend" aria-label="Legend">
            <li><span className="swatch block length" aria-hidden="true"></span>Length</li>
            <li><span className="swatch block checksum" aria-hidden="true"></span>Checksum</li>
            <li><span className="swatch block payload" aria-hidden="true"></span>Payload</li>
          </ul>
          {result?.status === "ok" && (
            <div className="verdict" role="status">
              <p><strong>The log opened.</strong> It recovered {result.records.length} records{result.truncated > 0 ? ` and cut off ${result.truncated} torn bytes` : ""}.</p>
              {lost > 0 && <p>The program reported {log.acknowledged.length} writes done, so <strong>{lost} acknowledged {lost === 1 ? "write is" : "writes are"} gone</strong>. That's the price of reporting success before an fsync.</p>}
              {result.records.length > 0 && <p className="records">{result.records.join(" · ")}</p>}
            </div>
          )}
          {result?.status === "refused" && (
            <div className="verdict refused" role="status">
              <p><strong>The log refused to open.</strong> The record starting at byte {result.offset} is damaged ({result.cause === "corrupt" ? "its checksum doesn't match" : "its length is impossible"}), and it isn't a torn tail, so it isn't an unfinished write. Throwing the rest away quietly is how data disappears unnoticed.</p>
            </div>
          )}
        </>
      )}
    </div>
  );
}
