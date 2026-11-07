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

`src/lib/links.ts` holds an allowlist: `JOURNEY.md`, and the Markdown under `lessons/`, `math/`, `dsa/`, `system-design/`, `capstones/` and `open-source/`. Anything else, such as `notes/` or `plan.md`, stays out, and a link to it goes to GitHub instead. A test keeps it that way.

## Assessment and ownership navigation

The homepage links to `/ownership/`, where learners choose junior, intermediate or senior practice. The selector reads the phase list from JOURNEY, links to the corresponding headings in each phase's `assessment.md`, and keeps only the route preference in browser storage. It does not assign a job title, record reviewer sign-off or mark operational evidence complete. Direct course links remain available without JavaScript or storage.

Each phase's lesson navigation includes an Assessment tab when that document is published. `tests/assessment.test.ts` checks all three route anchors for every phase against the actual Markdown headings, so renaming an assessment heading must also update the route metadata in `src/lib/assessment.ts`.

The publishing allowlist still excludes the root `plan.md`, personal notes and lesson templates. Phase 8's dated experiment plan/report under its public lesson evidence directory are intentionally published; raw JSON, logs and public signature material link to GitHub. Weight blobs, private keys and bearer tokens must never be added to that evidence.

## Adding a lab

Put the logic in `src/sim/` as plain TypeScript with a test in `tests/`, the interface in `src/islands/`, and the page in `src/pages/labs/`. Add it to the labs index. A lab says what it leaves out.

## Deploying on Vercel

Import the repository, set **Root Directory** to `site`, and leave the rest at Astro's defaults. Keep "Include files outside the root directory" on, because the build reads the Markdown one level up.
