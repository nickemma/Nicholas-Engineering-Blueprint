import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";
import { parseJourney, totalWeeks } from "../src/lib/journey.ts";
import { isPublished, resolveHref, resolveImage, urlOf, type LinkIndex } from "../src/lib/links.ts";

const files = new Set([
  "JOURNEY.md",
  "lessons/00-a/README.md",
  "lessons/00-a/TEACHING.md",
  "math/README.md",
  "math/01-queueing/README.md",
]);
const index: LinkIndex = {
  has: (file) => files.has(file),
  pageOf: (file, anchor) =>
    file === "lessons/00-a/TEACHING.md" && anchor === "the-trap"
      ? "/lessons/00-a/guide/step-2/"
      : undefined,
};

test("private files and templates are never published", () => {
  for (const file of ["career.md", "plan.md", "README.md", "notes/failures.md", "notes/learned/00-a.md"]) {
    assert.equal(isPublished(file), false, file);
  }
  for (const file of ["lessons/_TEMPLATE.md", "system-design/_template.md", "lessons/00-a/practice/x.md"]) {
    assert.equal(isPublished(file), false, file);
  }
  for (const file of files) assert.equal(isPublished(file), true, file);
});

test("files map to urls", () => {
  assert.equal(urlOf("JOURNEY.md"), "/journey/");
  assert.equal(urlOf("lessons/00-a/README.md"), "/lessons/00-a/");
  assert.equal(urlOf("lessons/00-a/TEACHING.md"), "/lessons/00-a/guide/");
  assert.equal(urlOf("lessons/00-a/exercises.md"), "/lessons/00-a/exercises/");
  assert.equal(urlOf("capstones/01-kestrel.md"), "/capstones/01-kestrel/");
});

test("links between published files stay on the site", () => {
  assert.equal(resolveHref("TEACHING.md", "lessons/00-a/README.md", index), "/lessons/00-a/guide/");
  assert.equal(resolveHref("../../math/README.md", "lessons/00-a/README.md", index), "/math/");
  assert.equal(resolveHref("../../math/", "lessons/00-a/README.md", index), "/math/");
  assert.equal(resolveHref("lessons/00-a", "JOURNEY.md", index), "/lessons/00-a/");
});

test("anchors find the page of a split guide", () => {
  assert.equal(
    resolveHref("TEACHING.md#the-trap", "lessons/00-a/README.md", index),
    "/lessons/00-a/guide/step-2/#the-trap",
  );
  assert.equal(resolveHref("#the-trap", "lessons/00-a/TEACHING.md", index), "/lessons/00-a/guide/step-2/#the-trap");
  assert.equal(
    resolveHref("../../math/01-queueing/README.md#the-clock-lied", "lessons/00-a/README.md", index),
    "/math/01-queueing/#the-clock-lied",
  );
});

test("everything else goes to GitHub, and external links are left alone", () => {
  const repo = "https://github.com/nickemma/Nicholas-Engineering-Blueprint";
  assert.equal(resolveHref("scripts/check_guides.py", "JOURNEY.md", index), `${repo}/blob/main/scripts/check_guides.py`);
  assert.equal(resolveHref("notes/", "JOURNEY.md", index), `${repo}/tree/main/notes`);
  assert.equal(resolveHref("https://go.dev/", "JOURNEY.md", index), "https://go.dev/");
  assert.equal(resolveHref("mailto:a@b.c", "JOURNEY.md", index), "mailto:a@b.c");
});

test("images load from the repository", () => {
  assert.equal(
    resolveImage("images/a.png", "lessons/00-a/TEACHING.md"),
    "https://raw.githubusercontent.com/nickemma/Nicholas-Engineering-Blueprint/main/lessons/00-a/images/a.png",
  );
});

test("the real route parses", () => {
  const stops = parseJourney(fs.readFileSync("../JOURNEY.md", "utf8"));
  assert.equal(stops.length, 14);
  assert.equal(stops[0].url, "/lessons/00-request-service/");
  assert.equal(stops.filter((stop) => stop.bridge).length, 4);
  assert.equal(stops.at(-1)!.url, "/capstones/");
  assert.equal(totalWeeks(stops), 83);
  assert.equal(new Set(stops.map((stop) => stop.id)).size, 14);
});
