// Markdown links are written for GitHub. These functions turn them into links
// on the site, or into links to GitHub for anything the site doesn't publish.
import path from "node:path";

export const REPO = "https://github.com/nickemma/Nicholas-Engineering-Blueprint";
const RAW = "https://raw.githubusercontent.com/nickemma/Nicholas-Engineering-Blueprint/main";

// The only Markdown the site publishes. Everything else, such as notes/ and
// plan.md, stays out, whatever is added to the repository later.
const PUBLISHED = /^(JOURNEY\.md|(lessons|math|dsa|system-design|capstones|open-source)\/.*\.md)$/;
const UNPUBLISHED = /(^|\/)(_[^/]*|practice)(\/|$)/;

export function isPublished(file: string): boolean {
  return PUBLISHED.test(file) && !UNPUBLISHED.test(file);
}

// JOURNEY.md is /journey/, and lessons/00-x/TEACHING.md is /lessons/00-x/guide/.
export function urlOf(file: string): string {
  if (file === "JOURNEY.md") return "/journey/";
  const page = file
    .replace(/\.md$/, "")
    .replace(/\/README$/, "")
    .replace(/\/TEACHING$/, "/guide");
  return `/${page}/`;
}

export interface LinkIndex {
  has(file: string): boolean;
  // The page that holds an anchor, for guides that are split across pages.
  pageOf(file: string, anchor: string): string | undefined;
}

function onSite(file: string, anchor: string, index: LinkIndex): string {
  if (!anchor) return urlOf(file);
  return `${index.pageOf(file, anchor) ?? urlOf(file)}#${anchor}`;
}

export function resolveHref(href: string, from: string, index: LinkIndex): string {
  if (/^([a-z][a-z0-9+.-]*:|\/\/)/i.test(href)) return href;
  const [target, anchor = ""] = href.split("#");
  if (!target) return onSite(from, anchor, index);

  const file = path.posix.normalize(path.posix.join(path.posix.dirname(from), target));
  const clean = file.replace(/\/$/, "");
  for (const candidate of [clean, `${clean}/README.md`]) {
    if (index.has(candidate)) return onSite(candidate, anchor, index);
  }
  // A link that climbs out of the repository can't be resolved.
  if (clean.startsWith("..")) return href;
  const kind = target.endsWith("/") || !path.posix.extname(clean) ? "tree" : "blob";
  return `${REPO}/${kind}/main/${clean}${anchor ? `#${anchor}` : ""}`;
}

export function resolveImage(src: string, from: string): string {
  if (/^([a-z][a-z0-9+.-]*:|\/\/)/i.test(src)) return src;
  return `${RAW}/${path.posix.normalize(path.posix.join(path.posix.dirname(from), src))}`;
}
