// Checks every internal link and anchor in the built site, in dist/.
import fs from "node:fs";
import path from "node:path";

const DIST = "dist";
const files = fs.readdirSync(DIST, { recursive: true }).filter((file) => file.endsWith(".html"));
const ids = new Map();
const pageOf = (file) => `/${file.replace(/index\.html$/, "")}`;

for (const file of files) {
  const html = fs.readFileSync(path.join(DIST, file), "utf8");
  ids.set(pageOf(file), new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((match) => match[1])));
}

const broken = new Map();
let checked = 0;
for (const file of files) {
  const html = fs.readFileSync(path.join(DIST, file), "utf8");
  for (const [, href] of html.matchAll(/<a\b[^>]*?\shref="([^"]+)"/g)) {
    const decoded = href.replaceAll("&#x26;", "&").replaceAll("&amp;", "&");
    if (/^[a-z][a-z0-9+.-]*:|^\/\//i.test(decoded)) continue;
    checked += 1;
    const [target, anchor] = decoded.split("#");
    const page = target || pageOf(file);
    const known = ids.get(page) ?? (fs.existsSync(path.join(DIST, page)) && !page.endsWith("/") ? new Set() : undefined);
    if (!known) broken.set(decoded, [...(broken.get(decoded) ?? []), pageOf(file)]);
    else if (anchor && ids.has(page) && !known.has(decodeURIComponent(anchor))) {
      broken.set(decoded, [...(broken.get(decoded) ?? []), pageOf(file)]);
    }
  }
}

console.log(`${files.length} pages, ${checked} internal links`);
for (const [href, pages] of broken) console.log(`broken: ${href}  (on ${pages[0]}${pages.length > 1 ? ` and ${pages.length - 1} more` : ""})`);
process.exit(broken.size === 0 ? 0 : 1);
