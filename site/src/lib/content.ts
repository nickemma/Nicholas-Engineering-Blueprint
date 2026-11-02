// Reads the repository's Markdown at build time and turns it into pages. Long
// guides split into one page per top-level section.
import fs from "node:fs";
import path from "node:path";
import GithubSlugger from "github-slugger";
import { toString } from "mdast-util-to-string";
import rehypeHighlight from "rehype-highlight";
import rehypeRaw from "rehype-raw";
import rehypeStringify from "rehype-stringify";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";
import { visit } from "unist-util-visit";
import { isPublished, resolveHref, resolveImage, urlOf, type LinkIndex } from "./links.ts";

export const ROOT = path.resolve(process.cwd(), "..");

export interface Heading {
  id: string;
  text: string;
  depth: number;
}

export interface Page {
  url: string; // with leading and trailing slashes
  file: string;
  title: string; // this page's title
  docTitle: string;
  html: string;
  headings: Heading[];
  siblings: { url: string; title: string }[]; // the sections of a split guide
  index: number;
  hasDiagram: boolean;
}

interface Section {
  url: string;
  title: string;
  children: any[];
}

interface Doc {
  file: string;
  title: string;
  sections: Section[];
  definitions: any[];
  anchors: Map<string, string>;
}

const parser = unified().use(remarkParse).use(remarkGfm);

function walk(dir: string, found: string[] = []): string[] {
  for (const entry of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
    if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
    const relative = path.posix.join(dir, entry.name);
    if (entry.isDirectory()) walk(relative, found);
    else if (entry.name.endsWith(".md") && isPublished(relative)) found.push(relative);
  }
  return found;
}

function files(): string[] {
  const dirs = ["lessons", "math", "dsa", "system-design", "capstones", "open-source"];
  return ["JOURNEY.md", ...dirs.flatMap((dir) => walk(dir))].sort();
}

function load(file: string): Doc {
  const tree: any = parser.parse(fs.readFileSync(path.join(ROOT, file), "utf8"));
  const first = tree.children.find((node: any) => node.type === "heading" && node.depth === 1);
  const title = first ? toString(first) : path.posix.basename(path.posix.dirname(file));
  const split = file.endsWith("/TEACHING.md");
  const definitions = tree.children.filter((node: any) => node.type === "definition");
  const slugger = new GithubSlugger();
  const sections: Section[] = [{ url: urlOf(file), title, children: [] }];
  const anchors = new Map<string, string>();

  for (const node of tree.children) {
    if (node.type === "definition") continue;
    if (node === first) continue;
    let id = "";
    if (node.type === "heading") {
      id = slugger.slug(toString(node));
      node.data = { hProperties: { id } };
      if (split && node.depth === 2) {
        sections.push({ url: `${urlOf(file)}${id}/`, title: toString(node), children: [] });
      }
    }
    const section = sections.at(-1)!;
    section.children.push(node);
    if (id) anchors.set(id, section.url);
  }
  return { file, title, sections, definitions, anchors };
}

function linkRewriter(file: string, index: LinkIndex) {
  return () => (tree: any) => {
    visit(tree, "element", (node: any) => {
      const props = node.properties ?? {};
      if (node.tagName === "a" && typeof props.href === "string") {
        props.href = resolveHref(props.href, file, index);
        if (/^https?:/.test(props.href)) props.rel = "noreferrer";
      }
      if (node.tagName === "img" && typeof props.src === "string") {
        props.src = resolveImage(props.src, file);
        props.loading = "lazy";
      }
    });
  };
}

function headingsOf(children: any[]): Heading[] {
  return children
    .filter((node) => node.type === "heading" && node.depth >= 2 && node.depth <= 3)
    .map((node) => ({ id: node.data.hProperties.id, text: toString(node), depth: node.depth }));
}

function build(): Map<string, Page> {
  const docs = new Map(files().map((file) => [file, load(file)]));
  const index: LinkIndex = {
    has: (file) => docs.has(file),
    pageOf: (file, anchor) => docs.get(file)?.anchors.get(anchor),
  };
  const pages = new Map<string, Page>();

  for (const doc of docs.values()) {
    const processor = unified()
      .use(remarkRehype, { allowDangerousHtml: true })
      .use(rehypeRaw)
      .use(linkRewriter(doc.file, index))
      .use(rehypeHighlight, { plainText: ["text", "mermaid", "tla", "markdown"], detect: false })
      .use(rehypeStringify);
    const splitGuide = doc.sections.length > 1;
    const siblings = doc.sections.map(({ url, title }) => ({ url, title }));

    doc.sections.forEach((section, i) => {
      const root: any = { type: "root", children: [...section.children, ...doc.definitions] };
      const body = processor.runSync(root);
      pages.set(section.url, {
        url: section.url,
        file: doc.file,
        title: section.title,
        docTitle: doc.title,
        html: processor.stringify(body as any),
        headings: splitGuide ? headingsOf(section.children).filter((h) => h.depth === 3) : headingsOf(section.children),
        siblings: splitGuide ? siblings : [],
        index: i,
        hasDiagram: section.children.some((node) => node.type === "code" && node.lang === "mermaid"),
      });
    });
  }
  return pages;
}

let cached: Map<string, Page> | undefined;

export function allPages(): Map<string, Page> {
  cached ??= build();
  return cached;
}

// The tabs of a lesson: syllabus, guide, exercises and answers.
export function tabsOf(file: string): { label: string; url: string }[] {
  const match = file.match(/^lessons\/[^/]+\//);
  if (!match) return [];
  const pages = allPages();
  const tabs = [
    ["Syllabus", "README.md"],
    ["Guide", "TEACHING.md"],
    ["Exercises", "exercises.md"],
    ["Answers", "learned.md"],
  ];
  return tabs
    .map(([label, name]) => ({ label, url: urlOf(match[0] + name) }))
    .filter((tab) => pages.has(tab.url));
}

export function pagesUnder(prefix: string): Page[] {
  return [...allPages().values()].filter(
    (page) => page.url.startsWith(prefix) && page.url !== prefix && page.index === 0,
  );
}
