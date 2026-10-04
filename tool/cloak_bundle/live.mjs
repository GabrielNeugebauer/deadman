// Live Cloak runtime for tool/mainnet_e2e.dart: serves assets/cloak to
// headless Chromium (as smoke.mjs does) and bridges `deadmanCloak.run` over
// stdin/stdout, one JSON object per line. Unlike smoke.mjs this signs and
// sends real transactions with the claim key.
//
//   node live.mjs --secret-file <keypair.json>   bridge mode (see below)
//   node live.mjs --ping                         launch check, no key, no RPC
//
// The claim key comes from a Solana CLI keypair file (64-byte JSON array),
// never from argv or stdin, and is added to every request that carries no
// `secret` or `spendKey` of its own. Requests: {"id", "op", "payload"} with
// `payload` a JSON string; replies: {"id", "reply"}. The first stdout line is
// {"ready": true, "version", "address"}, where `address` is the claim key's
// public key from the file. Page console output goes to stderr.
//
// The page calls the RPC passed in each payload directly, so it must allow
// browser requests (e.g. Helius; api.mainnet-beta.solana.com answers 403).
import { getBase58Decoder } from "@solana/kit";
import { chromium } from "playwright";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const assets = fileURLToPath(new URL("../../assets/cloak/", import.meta.url));
const argv = process.argv.slice(2);
const ping = argv.includes("--ping");
const secretFile = argv[argv.indexOf("--secret-file") + 1];
if (!ping && (!argv.includes("--secret-file") || !secretFile)) {
  console.error("usage: node live.mjs --secret-file <keypair.json> | --ping");
  process.exit(64);
}

let secret = null;
let address = null;
if (!ping) {
  const bytes = Uint8Array.from(JSON.parse(readFileSync(secretFile, "utf8")));
  if (bytes.length !== 64) throw new Error("secret file must be a 64-byte Solana keypair");
  // The app hands the runtime the 32-byte private key (Ed25519HDKeyPair.extract).
  secret = Buffer.from(bytes.slice(0, 32)).toString("base64");
  address = getBase58Decoder().decode(bytes.slice(32));
}

const types = { ".html": "text/html", ".js": "text/javascript" };
const server = createServer((req, res) => {
  const name = new URL(req.url, "http://x").pathname.replace(/^\//, "") || "index.html";
  if (!["index.html", "cloak.js"].includes(name)) return res.writeHead(404).end();
  res.writeHead(200, { "Content-Type": types[name.slice(name.lastIndexOf("."))] });
  res.end(readFileSync(assets + name));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));

const browser = await chromium.launch();
const page = await browser.newPage();
page.on("console", (m) => console.error(`[cloak] ${m.text().slice(0, 300)}`));
page.on("pageerror", (e) => console.error(`[cloak] page error: ${e.message}`));
await page.goto(`http://localhost:${server.address().port}/index.html`);
await page.waitForFunction(() => globalThis.deadmanCloak !== undefined);
const version = await page.evaluate(() => globalThis.deadmanCloak.version);

async function shutdown(code) {
  await browser.close().catch(() => {});
  server.close();
  process.exit(code);
}

if (ping) {
  const reply = JSON.parse(await page.evaluate(() => globalThis.deadmanCloak.run("ping", "{}")));
  console.log(JSON.stringify({ ok: reply.ok === true, version: reply.result?.version ?? null, chromium: browser.version() }));
  await shutdown(reply.ok ? 0 : 1);
}

const write = (obj) => process.stdout.write(`${JSON.stringify(obj)}\n`);
write({ ready: true, version, address });

const lines = createInterface({ input: process.stdin });
let queue = Promise.resolve();
lines.on("line", (line) => {
  queue = queue.then(async () => {
    let id = null;
    try {
      const req = JSON.parse(line);
      id = req.id;
      const payload = JSON.parse(req.payload);
      if (payload.secret === undefined && payload.spendKey === undefined) payload.secret = secret;
      const reply = await page.evaluate(([o, p]) => globalThis.deadmanCloak.run(o, p), [req.op, JSON.stringify(payload)]);
      write({ id, reply });
    } catch (e) {
      write({ id, reply: JSON.stringify({ ok: false, error: `bridge: ${e instanceof Error ? e.message : e}` }) });
    }
  });
});
lines.on("close", () => queue.then(() => shutdown(0)));
