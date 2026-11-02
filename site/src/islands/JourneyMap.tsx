import { useEffect, useState } from "react";
import type { Stop } from "../lib/journey.ts";

const KEY = "blueprint.progress.v1";

export default function JourneyMap({ stops }: { stops: Stop[] }) {
  const [done, setDone] = useState<string[]>([]);

  useEffect(() => {
    try {
      const saved = JSON.parse(localStorage.getItem(KEY) ?? "[]");
      if (Array.isArray(saved)) setDone(saved);
    } catch {
      // A damaged entry starts the map again.
    }
  }, []);

  function toggle(id: string) {
    const changed = done.includes(id) ? done.filter((item) => item !== id) : [...done, id];
    setDone(changed);
    localStorage.setItem(KEY, JSON.stringify(changed));
  }

  const finished = stops.filter((stop) => done.includes(stop.id)).length;
  const upNext = stops.find((stop) => !done.includes(stop.id));

  return (
    <div className="route">
      <p className="route-count" aria-live="polite">
        {finished} of {stops.length} finished
        {upNext && (
          <>
            {" · up next: "}
            <a href={upNext.url}>{upNext.title}</a>
          </>
        )}
      </p>
      <ol>
        {stops.map((stop) => {
          const isDone = done.includes(stop.id);
          return (
            <li key={stop.id} className={["stop", stop.bridge && "bridge", isDone && "done"].filter(Boolean).join(" ")}>
              <input
                type="checkbox"
                id={`stop-${stop.id}`}
                checked={isDone}
                onChange={() => toggle(stop.id)}
                aria-label={`Mark ${stop.title} as finished`}
              />
              <div>
                <h3>
                  <a href={stop.url}>{stop.title}</a>
                </h3>
                <p className="question">{stop.question}</p>
                <p className="build">{stop.build}</p>
                <p className="meta">
                  {stop.weeks} weeks · {stop.status}
                </p>
              </div>
            </li>
          );
        })}
      </ol>
    </div>
  );
}
