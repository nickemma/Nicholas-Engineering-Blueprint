import { useEffect, useState } from "react";
import { LEVELS, assessmentPhases, assessmentUrl, isLevel, type Level } from "../lib/assessment.ts";
import type { Stop } from "../lib/journey.ts";

export default function AssessmentRoutes({ stops }: { stops: Stop[] }) {
  const [level, setLevel] = useState<Level>("junior");
  const [saved, setSaved] = useState(false);
  useEffect(() => {
    try {
      const requested = window.location.hash.slice(1);
      const value = isLevel(requested) ? requested : localStorage.getItem("blueprint.assessment-route.v1");
      if (isLevel(value)) setLevel(value);
    } catch { /* Route navigation still works when storage is unavailable. */ }
  }, []);
  function select(value: Level) {
    setLevel(value);
    try {
      history.replaceState(null, "", `#${value}`);
      localStorage.setItem("blueprint.assessment-route.v1", value);
      setSaved(true);
    } catch { setSaved(false); }
  }
  const route = LEVELS.find((item) => item.id === level)!;
  return (
    <div className="assessment-routes">
      <fieldset className="route-options">
        <legend>Choose the independence you want to practise</legend>
        {LEVELS.map((item) => (
          <label id={item.id} key={item.id} className={level === item.id ? "selected" : ""}>
            <input type="radio" name="assessment-route" value={item.id} checked={level === item.id} onChange={() => select(item.id)} />
            <span><strong>{item.title}</strong><small>{item.focus}</small></span>
          </label>
        ))}
      </fieldset>
      <section className="route-summary" aria-live="polite" aria-atomic="true">
        <h2>{route.title}: {route.focus.toLowerCase()}</h2>
        <p>{route.description}</p>
        {level === "junior" ? (
          <p>Begin with Phases 0–1 for a reliable service, continue through Phase 2 for connected services, and through Phase 3 for a durable backend foundation. Follow the bridge prerequisites. <a href="/lessons/ownership/beginner/">Read the minimum route</a>.</p>
        ) : (
          <p>Demonstrate the phase prerequisites before taking its independent assignment. From Phase 5, run the <a href="/lessons/ownership/sustained/">twelve-week ownership exercise</a> alongside your phase work.</p>
        )}
        <p className="route-limit">This choice is a practice route, not a job-title certification or a review verdict. {saved && "Your preference is saved in this browser."}</p>
      </section>
      <ol className="assessment-list">
        {assessmentPhases(stops).map((stop) => (
          <li key={stop.id}>
            <div><h3><a href={assessmentUrl(stop, level)}>{stop.title}</a></h3><p>{stop.question}</p></div>
            <a className="assessment-action" href={assessmentUrl(stop, level)}>{route.title} assignment <span aria-hidden="true">→</span></a>
          </li>
        ))}
      </ol>
      <noscript><p>JavaScript is optional for the course. Open the <a href="/lessons/ownership/">track guide</a> for direct links to every phase and route.</p></noscript>
    </div>
  );
}
