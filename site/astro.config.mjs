import react from "@astrojs/react";
import { defineConfig } from "astro/config";
import legacyLessonRoutes from "./src/lib/legacy-lesson-routes.json" with { type: "json" };

export default defineConfig({
  integrations: [react()],
  trailingSlash: "always",
  redirects: legacyLessonRoutes,
});
