import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import test from "node:test";

const app = await readFile(new URL("../src/App.svelte", import.meta.url), "utf8");
const css = await readFile(new URL("../src/style.css", import.meta.url), "utf8");
const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
const favicon = await readFile(new URL("../public/favicon.svg", import.meta.url), "utf8");
const assetDirectory = new URL("../dist/assets/", import.meta.url);
const javascriptBundle = (
  await Promise.all(
    (await readdir(assetDirectory))
      .filter((name) => name.endsWith(".js"))
      .map((name) => readFile(new URL(name, assetDirectory), "utf8"))
  )
).join("\n");

test("the useful demo precedes supporting architecture content", () => {
  assert.ok(app.indexOf('id="demo"') < app.indexOf('id="how-it-works"'));
  assert.match(html, /width=device-width, initial-scale=1\.0/);
});

test("the site ships a neon-yellow SVG favicon", () => {
  assert.match(html, /<link rel="icon" href="\/favicon\.svg" type="image\/svg\+xml"/);
  assert.match(favicon, /<svg[^>]+viewBox="0 0 64 64"/);
  assert.match(favicon, /#f5ff38|#f8ff58/);
  assert.match(favicon, /filter="url\(#glow\)"/);
});

test("typography uses fonts that are available without a network request", () => {
  assert.match(css, /--font-sans: -apple-system, BlinkMacSystemFont/);
  assert.match(css, /--font-mono: ui-monospace, "SFMono-Regular"/);
  assert.doesNotMatch(css, /\bInter\b|DM Mono/);
});

test("mobile styles preserve readable controls and compact the hero", () => {
  const mobile = css.slice(css.indexOf("@media (max-width: 760px)"));

  assert.match(mobile, /\.hero-actions\s*\{[^}]*flex-direction: column/s);
  assert.match(mobile, /\.route\s*\{[^}]*grid-template-columns: minmax\(0, 1fr\)/s);
  assert.match(mobile, /form input\s*\{[^}]*font-size: 16px/s);
  assert.match(css, /\.command button\s*\{[^}]*min-height: 44px/s);
  assert.match(css, /\.rune-field button\s*\{[^}]*height: 44px/s);
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/);
});

test("the voltage strip is a continuous ticker", () => {
  assert.equal((app.match(/class="voltage-group"/g) ?? []).length, 2);
  assert.match(css, /@keyframes ticker/);
  assert.match(css, /\.voltage-track\s*\{[^}]*animation: ticker/s);
});

test("the SDK section links to package and authoritative developer documentation", () => {
  assert.match(app, /https:\/\/www\.npmjs\.com\/package\/@zaptunnel\/sdk/);
  assert.match(app, /https:\/\/docs\.corelightning\.org\/reference\//);
  assert.match(app, /https:\/\/docs\.corelightning\.org\/reference\/createrune/);
  assert.match(app, /paidInvoices\(\)/);
  assert.match(app, /createConnectionManager/);
  assert.match(app, /One resilient connection/);
  assert.match(css, /\.sdk-resources\s*\{[^}]*grid-template-columns: repeat\(2/s);
});

test("the front page identifies Core Lightning compatibility without implying endorsement", () => {
  assert.match(app, /Browser access for Core Lightning/);
  assert.match(app, /https:\/\/docs\.corelightning\.org\/docs\/home/);
  assert.match(app, /08-transport\.md/);
  assert.match(app, /https:\/\/docs\.corelightning\.org\/reference\/commando/);
  assert.match(app, /https:\/\/blockstream\.com\/lightning\//);
  assert.match(app, /independent project and is not affiliated with or endorsed/);
});

test("the connection form documents clearnet and v3 onion addresses", () => {
  assert.match(app, /clearnet or v3 onion/);
  assert.match(app, /\.onion:9735/);
});

test("the node ID pattern survives Svelte compilation and accepts a real compressed key", () => {
  const nodeId = "02cca6c5c966fcf61d121e3a70e03a1cd9eeeea024b26ea666ce974d43b242e636";
  const nodeIdPattern = /^(02|03)[0-9a-fA-F]{64}$/;

  assert.equal(nodeId.length, 66);
  assert.match(nodeId, nodeIdPattern);
  assert.match(app, /pattern=\{nodeIdPattern\}/);
  assert.match(javascriptBundle, /\(02\|03\)\[0-9a-fA-F\]\{64\}/);
  assert.doesNotMatch(javascriptBundle, /\(02\|03\)\[0-9a-fA-F\]64/);
});
