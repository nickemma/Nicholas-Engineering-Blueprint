import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";
import { LEVELS, assessmentPhases, assessmentUrl } from "../src/lib/assessment.ts";
import { allPages, tabsOf } from "../src/lib/content.ts";
import { parseJourney } from "../src/lib/journey.ts";

test("every phase's three route links resolve to real assessment headings and a lesson tab", () => {
  const stops = parseJourney(fs.readFileSync("../JOURNEY.md", "utf8"));
  const phases = assessmentPhases(stops);
  assert.equal(phases.length, 9);
  const pages = allPages();
  for (const phase of phases) {
    for (const level of LEVELS) {
      const [url, anchor] = assessmentUrl(phase, level.id).split("#");
      const page = pages.get(url);
      assert.ok(page, url);
      assert.ok(page.headings.some((heading) => heading.id === anchor), `${url}#${anchor}`);
      assert.ok(tabsOf(page.file).some((tab) => tab.label === "Assessment" && tab.url === url));
    }
  }
});
