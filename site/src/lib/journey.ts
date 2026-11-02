// The route comes from the table in JOURNEY.md, so the site can't disagree with
// the map.
import { urlOf } from "./links.ts";

export interface Stop {
  id: string;
  title: string;
  question: string;
  build: string;
  weeks: string;
  status: string;
  url: string;
  bridge: boolean;
}

const HEADER = "| Phase | Question | You build | Weeks | Status |";

const plain = (text: string) => text.replace(/\*\*|`/g, "").trim();

export function parseJourney(markdown: string): Stop[] {
  const lines = markdown.split("\n");
  const start = lines.findIndex((line) => line.trim() === HEADER);
  if (start < 0) throw new Error("JOURNEY.md: the route table is missing");
  const stops: Stop[] = [];
  for (const line of lines.slice(start + 2)) {
    if (!line.startsWith("|")) break;
    const cells = line.split("|").slice(1, -1).map((cell) => cell.trim());
    const link = cells[0].match(/^\[(.+)\]\((.+)\)$/);
    if (!link || cells.length !== 5) throw new Error(`JOURNEY.md: bad route row: ${line}`);
    const file = link[2];
    stops.push({
      id: file.replace(/\/README\.md$/, "").replace(/^.*\//, ""),
      title: link[1],
      question: plain(cells[1]),
      build: plain(cells[2]),
      weeks: plain(cells[3]),
      status: plain(cells[4]),
      url: urlOf(file),
      bridge: link[1].includes("Bridge"),
    });
  }
  return stops;
}

// "~8" and "10+" count as 8 and 10.
export function totalWeeks(stops: Stop[]): number {
  return stops.reduce((sum, stop) => sum + (Number(stop.weeks.replace(/\D/g, "")) || 0), 0);
}
