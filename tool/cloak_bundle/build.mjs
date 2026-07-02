// Bundles src/entry.mjs into ../../assets/cloak/cloak.js for the WebView.
import { build } from "esbuild";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const out = fileURLToPath(new URL("../../assets/cloak/cloak.js", import.meta.url));
const empty = fileURLToPath(new URL("src/empty.mjs", import.meta.url));

await build({
  entryPoints: [fileURLToPath(new URL("src/entry.mjs", import.meta.url))],
  outfile: out,
  bundle: true,
  format: "iife",
  platform: "browser",
  target: ["chrome110"],
  minify: true,
  legalComments: "none",
  inject: [fileURLToPath(new URL("src/shims.mjs", import.meta.url))],
  define: { global: "globalThis" },
  alias: { fs: empty, path: empty, crypto: empty, os: empty, worker_threads: empty, readline: empty, constants: empty, url: empty },
  logLevel: "warning",
});

const bytes = readFileSync(out);
console.log(`${out} ${bytes.length} bytes sha256=${createHash("sha256").update(bytes).digest("hex")}`);
