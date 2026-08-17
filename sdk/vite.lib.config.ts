import { defineConfig } from "vite";
import { resolve } from "node:path";

export default defineConfig({
  build: {
    emptyOutDir: false,
    lib: {
      entry: resolve(import.meta.dirname, "src/index.ts"),
      formats: ["es"],
      fileName: "index"
    },
    outDir: "dist/lib",
    rollupOptions: {
      output: {
        inlineDynamicImports: true
      }
    }
  }
});
