/**
 * esbuild.js — bundles the QuickLookCode tokenizer
 *
 * Produces one bundle:
 *
 *   tokenizer-jsc.js  — JavaScriptCore build used by the QL extension.
 *                       Expects `globalThis.onigLib` to be pre-installed by
 *                       Swift (native oniguruma). Fully synchronous, no WASM.
 *
 * Usage:
 *   pnpm install       # first time only
 *   pnpm run build     # produces the bundle
 */

import esbuild from "esbuild";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const resources = resolve(__dirname, "../QuickLookCode/QuickLookCodeShared/Resources");
const watchMode = process.argv.includes("--watch");

const jscCtx = await esbuild.context({
  entryPoints: [resolve(__dirname, "src/tokenizer-jsc.js")],
  bundle: true,
  format: "iife",
  platform: "neutral",
  mainFields: ["module", "main"],  // neutral platform doesn't resolve these by default
  target: ["es2022"],               // JSC on macOS 13 supports ES2022
  outfile: resolve(resources, "tokenizer-jsc.js"),
  minify: !watchMode,
  sourcemap: false,
  logLevel: "info",
});

if (watchMode) {
  await jscCtx.watch();
  console.log("Watching for changes…");
} else {
  await jscCtx.rebuild();
  await jscCtx.dispose();
  console.log(`\nBuilt JSC bundle → ${resources}/tokenizer-jsc.js`);
}
