# The Blueprint's site

The website for the Blueprint, built with Astro, with React islands for the interactive parts. It holds no lesson content of its own: at build time it reads the Markdown in this repository, so the guides stay the single source.

~~~bash
cd site
npm install
npm run dev      # http://localhost:4321
npm test         # the simulations, the link rewriting and the publishing rules
npm run build    # the static site, in dist/
npm run check:links   # every internal link and anchor in dist/
~~~

## What gets published

`src/lib/links.ts` holds an allowlist: `JOURNEY.md`, and the Markdown under `1-foundations/`, `2-core/`, `3-tracks/`, `math/`, `dsa/`, `system-design/` and `ownership/`. Folders named `evidence/` or `practice/`, and names starting with `_`, stay out: a link to them goes to GitHub instead. So does anything outside the allowlist, such as `README.md` or `career.md`. A test keeps it that way.

Raw evidence (JSON, logs, signature material) is linked on GitHub, not published. Weight blobs, private keys and bearer tokens must never be added to it.

## Adding a lab

Put the logic in `src/sim/` as plain TypeScript with a test in `tests/`, the interface in `src/islands/`, and the page in `src/pages/labs/`. Add it to the labs index. A lab says what it leaves out.

## Deploying on Vercel

Import the repository, set **Root Directory** to `site`, and leave the rest at Astro's defaults. Keep "Include files outside the root directory" on, because the build reads the Markdown one level up.
