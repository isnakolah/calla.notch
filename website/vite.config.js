import { defineConfig } from "vite";
import { resolve } from "node:path";
export default defineConfig({
  server: {
    proxy: {
      "/api": "http://127.0.0.1:4188",
      "/healthz": "http://127.0.0.1:4188",
    },
  },
  // Keep content-hashed chunks available to tabs opened before a local rebuild.
  build: {
    emptyOutDir: false,
    rolldownOptions: {
      input: {
        main: resolve(import.meta.dirname, "index.html"),
        admin: resolve(import.meta.dirname, "admin.html"),
      },
    },
  },
});
