// The route comes from the tables in JOURNEY.md, so the site can't disagree with
// the map. Every route table has the same header; the stage is the "### "
// heading above it, and a track's name is the bold link just before its table.
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
  stage: string;
}

const HEADER = "| Module | You build | Gate | Weeks | Status |";

const plain = (text: string) => text.replace(/\*\*|`/g, "").trim();

export function parseJourney(markdown: string): Stop[] {
  const lines = markdown.split("\n");
  if (!lines.some((line) => line.trim() === HEADER)) throw new Error("JOURNEY.md: the route tables are missing");
  const stops: Stop[] = [];
  let stage = "";
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith("### ")) stage = plain(line.slice(4));
    const track = line.match(/^\*\*\[(.+?)\]\(/);
    if (track) stage = track[1];
    if (line.trim() !== HEADER) continue;
    for (const row of lines.slice(i + 2)) {
      if (!row.startsWith("|")) break;
      const cells = row.split("|").slice(1, -1).map((cell) => cell.trim());
      const link = cells[0].match(/^\[(.+)\]\((.+)\)$/);
      if (!link || cells.length !== 5) throw new Error(`JOURNEY.md: bad route row: ${row}`);
      const file = link[2];
      stops.push({
        id: file.replace(/\/README\.md$/, ""),
        title: link[1],
        question: plain(cells[1]),
        build: `Gate: ${plain(cells[2])}`,
        weeks: plain(cells[3]),
        status: plain(cells[4]),
        url: urlOf(file),
        bridge: stage === "Shared units",
        stage,
      });
    }
  }
  return stops;
}

// "~8" and "10+" count as 8 and 10; "<1" counts as 0.
export function totalWeeks(stops: Stop[]): number {
  return stops.reduce(
    (sum, stop) => sum + (stop.weeks.startsWith("<") ? 0 : Number(stop.weeks.replace(/\D/g, "")) || 0),
    0,
  );
}
