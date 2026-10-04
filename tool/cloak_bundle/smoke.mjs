// Runs assets/cloak in headless Chromium against live mainnet read APIs and
// prints a pass/fail table. Random unfunded keys only; nothing is signed or
// sent. `npx playwright install chromium-headless-shell` once, then
// `node smoke.mjs`.
//
// RPC: CLOAK_SMOKE_RPC if set (must allow browser requests and serve
// getSignaturesForAddress history). Otherwise the page talks to a stand-in
// https host that this script forwards to UPSTREAM_RPC, the way a
// browser-friendly RPC such as Helius would behave. Through that stand-in
// the script can also add one synthetic delivery carrier, sealed with the
// unbundled SDK to a test identity, to drive the receive path end to end.
import * as cloak from "@cloak.dev/sdk";
import { getBase58Decoder } from "@solana/kit";
import { sha256 } from "@noble/hashes/sha2";
import { chromium } from "playwright";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";

const assets = fileURLToPath(new URL("../../assets/cloak/", import.meta.url));
const upstream = process.env.UPSTREAM_RPC ?? "https://api.mainnet-beta.solana.com";
const proxied = "https://rpc.smoke.invalid/";
const rpcUrl = process.env.CLOAK_SMOKE_RPC ?? proxied;
const noHistoryRpc = "https://solana-rpc.publicnode.com";
const DELIVERY_REGISTRY = "Da57wQTWvtVfm6bwLQRpsA4Yxhg61wLpeehn2UrELqib";
const USDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
const b64 = (n) => randomBytes(n).toString("base64");
const hostOf = (u) => new URL(u).host;

const types = { ".html": "text/html", ".js": "text/javascript" };
const server = createServer((req, res) => {
  const name = new URL(req.url, "http://x").pathname.replace(/^\//, "") || "index.html";
  if (!["index.html", "cloak.js"].includes(name)) return res.writeHead(404).end();
  res.writeHead(200, { "Content-Type": types[name.slice(name.lastIndexOf("."))] });
  res.end(readFileSync(assets + name));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const pageUrl = `http://localhost:${server.address().port}/index.html`;

const browser = await chromium.launch();
const version = browser.version();
const page = await browser.newPage();
const cspViolations = [];
const hosts = new Set();
page.on("console", (m) => {
  if (m.text().includes("Content Security Policy")) cspViolations.push(m.text().slice(0, 200));
});
page.on("request", (r) => hosts.add(new URL(r.url()).host));
const rpcCall = (method, params) =>
  fetch(upstream, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  }).then((r) => r.json());

let injected = null;
const fakeSig = getBase58Decoder().decode(randomBytes(64));

async function rewrite(body) {
  if (!injected) return null;
  const req = JSON.parse(body);
  if (req.method === "getSignaturesForAddress" && req.params[0] === DELIVERY_REGISTRY && !req.params[1]?.before) {
    const res = await rpcCall(req.method, req.params);
    const entry = { ...res.result[0], signature: fakeSig, memo: null };
    return { ...res, id: req.id, result: [entry, ...res.result].slice(0, req.params[1]?.limit ?? 1000) };
  }
  if (req.method === "getTransaction" && req.params[0] === fakeSig) {
    const sigs = await rpcCall("getSignaturesForAddress", [DELIVERY_REGISTRY, { limit: 1 }]);
    const res = await rpcCall("getTransaction", [sigs.result[0].signature, req.params[1]]);
    const msg = res.result.transaction.message;
    const memo = msg.accountKeys.indexOf("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr");
    for (const ix of msg.instructions) if (ix.programIdIndex === memo) ix.data = injected;
    return { ...res, id: req.id };
  }
  return null;
}

await page.route(`${proxied}**`, async (route) => {
  const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*" };
  if (route.request().method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors });
  const body = route.request().postData();
  const fake = await rewrite(body);
  const res = fake
    ? null
    : await fetch(upstream, { method: "POST", headers: { "Content-Type": "application/json" }, body });
  await route.fulfill({
    status: res?.status ?? 200,
    headers: { ...cors, "Content-Type": "application/json" },
    body: fake ? JSON.stringify(fake) : Buffer.from(await res.arrayBuffer()),
  });
});
await page.goto(pageUrl);
await page.waitForFunction(() => globalThis.deadmanCloak !== undefined);

async function run(op, payload) {
  const reply = await page.evaluate(
    ([o, p]) => globalThis.deadmanCloak.run(o, p),
    [op, JSON.stringify(payload)],
  );
  return JSON.parse(reply);
}

const rows = [];
async function check(name, op, payload, verify) {
  const t0 = Date.now();
  let pass = false;
  let detail;
  try {
    const reply = await run(op, payload);
    detail = verify(reply);
    pass = true;
  } catch (e) {
    detail = e instanceof Error ? e.message : String(e);
  }
  rows.push({ check: name, result: pass ? "PASS" : "FAIL", ms: Date.now() - t0, detail: String(detail).slice(0, 140) });
}

function ok(reply) {
  if (!reply.ok) throw new Error(`runtime error: ${reply.error}`);
  return reply.result;
}

function fails(reply, pattern) {
  if (reply.ok) throw new Error("expected an error");
  if (!pattern.test(reply.error)) throw new Error(`unexpected error: ${reply.error}`);
  return reply.error;
}

const isHex64 = (s) => /^[0-9a-f]{64}$/.test(s);
const claimSecret = b64(32);

await check("ping", "ping", {}, (r) => ok(r).version);

await check("receiveAddress (spend key)", "receiveAddress", { spendKey: b64(32) }, (r) => {
  const a = ok(r);
  if (!isHex64(a.utxoPubkey) || !isHex64(a.viewingPubkey)) throw new Error("bad address");
  return `cloak:${a.utxoPubkey.slice(0, 8)}…:${a.viewingPubkey.slice(0, 8)}…`;
});

let fromClaim;
await check("receiveAddress (claim key, deterministic)", "receiveAddress", { secret: claimSecret }, (r) => {
  fromClaim = ok(r);
  return `cloak:${fromClaim.utxoPubkey.slice(0, 8)}…`;
});
await check("receiveAddress repeat matches", "receiveAddress", { secret: claimSecret }, (r) => {
  const again = ok(r);
  if (again.utxoPubkey !== fromClaim?.utxoPubkey || again.viewingPubkey !== fromClaim?.viewingPubkey) {
    throw new Error("derivation is not deterministic");
  }
  return "same address";
});

const timing = (t) => `download ${t.downloadMs}ms, prove ${t.proveMs}ms, total ${t.totalMs}ms`;
await check("selfTest SOL (proof + risk quote, unsigned)", "selfTest", { rpcUrl }, (r) => {
  const t = ok(r);
  if (!t.reachedSigning) throw new Error("did not reach signing");
  return timing(t);
});
await check("selfTest SOL again (cached circuits)", "selfTest", { rpcUrl }, (r) => timing(ok(r)));
await check("selfTest USDC 1.0 (unsigned)", "selfTest", { rpcUrl, mint: USDC }, (r) => {
  const t = ok(r);
  if (!t.reachedSigning) throw new Error("did not reach signing");
  return timing(t);
});

const carriers = await fetch(rpcUrl === proxied ? upstream : rpcUrl, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "getSignaturesForAddress",
    params: [DELIVERY_REGISTRY, { limit: 1000 }],
  }),
})
  .then((r) => r.json())
  .then((j) => j.result.filter((s) => s.err === null).length);
await check("scanReceived fresh identity, every carrier read", "scanReceived", { rpcUrl, secret: b64(32) }, (r) => {
  const res = ok(r);
  if (res.notes.length !== 0) throw new Error(`expected 0 notes, got ${res.notes.length}`);
  if (res.rpcCalls < carriers + 2) throw new Error(`read ${res.rpcCalls - 2} of ${carriers} carriers`);
  return `0 notes, ${carriers} carriers opened, ${res.rpcCalls} RPC calls`;
});
await check("scanReceived refuses history-less RPC", "scanReceived", { rpcUrl: noHistoryRpc, secret: b64(32) }, (r) =>
  fails(r, /no history/),
);

// Unbundled-SDK side of the receive path: the claim key's receive identity,
// derived the way entry.mjs does, and a USDC note sealed to it.
const seed = Buffer.from(claimSecret, "base64");
const receiveKey = sha256(Buffer.concat([Buffer.from("deadman/cloak/receive/v1"), seed]));
const owner = await cloak.deriveUtxoKeypairFromSpendKey(new Uint8Array(receiveKey));
const ownerNk = cloak.getNkFromUtxoPrivateKey(owner.privateKey);
const ownerViewing = cloak.deriveViewingKeyFromNk(ownerNk).publicKey;
rows.push({
  check: "bundle derivation == unbundled SDK",
  result:
    fromClaim?.utxoPubkey === owner.publicKey.toString(16).padStart(64, "0") &&
    fromClaim?.viewingPubkey === Buffer.from(ownerViewing).toString("hex")
      ? "PASS"
      : "FAIL",
  ms: 0,
  detail: "receive utxo pubkey + viewing key",
});
const sealed = { amount: 2500000n, blinding: cloak.randomFieldElement() };
const sealedCommitment = await cloak.computeUtxoCommitment({
  ...sealed,
  keypair: { privateKey: 0n, publicKey: owner.publicKey },
  mintAddress: cloak.address(USDC),
});
injected = getBase58Decoder().decode(
  cloak.encodeDeliveryCarrierMemo(sealedCommitment, cloak.encodeRecipientDeliveryNote(sealed, ownerViewing)),
);
let found;
await check("scanReceived finds a note sealed to it (synthetic carrier)", "scanReceived", { rpcUrl, secret: claimSecret }, (r) => {
  const res = ok(r);
  found = res.notes;
  const n = res.notes[0];
  if (res.notes.length !== 1) throw new Error(`expected 1 note, got ${res.notes.length}`);
  if (n.commitment !== sealedCommitment.toString(16).padStart(64, "0")) throw new Error("wrong commitment");
  if (n.amount !== "2500000" || n.mint !== USDC || n.spent !== false || n.index !== null) {
    throw new Error(`unexpected note ${JSON.stringify({ ...n, blinding: undefined })}`);
  }
  return "1 note: 2.5 USDC, unspent, not in the relay tree (synthetic)";
});
await check("scanReceived ignores a note sealed to someone else", "scanReceived", { rpcUrl, secret: b64(32) }, (r) => {
  const res = ok(r);
  if (res.notes.length !== 0) throw new Error(`expected 0 notes, got ${res.notes.length}`);
  return "0 notes";
});
await check("withdrawReceived accepts own note, stops at relay leaf lookup", "withdrawReceived", {
  rpcUrl,
  secret: claimSecret,
  destination: "11111111111111111111111111111112",
  notes: found ?? [],
}, (r) => fails(r, /not indexed by the Cloak relay/));
injected = null;

await check("withdrawReceived rejects foreign note", "withdrawReceived", {
  rpcUrl,
  secret: claimSecret,
  destination: "11111111111111111111111111111112",
  notes: [{ commitment: "0".repeat(63) + "1", amount: "20000000", mint: null, blinding: "0".repeat(63) + "2" }],
}, (r) => fails(r, /does not belong/));

await check("shieldAndSend USDC below 1 USDC minimum", "shieldAndSend", {
  rpcUrl,
  secret: b64(32),
  mint: USDC,
  amount: "999999",
  recipientSolana: "11111111111111111111111111111112",
}, (r) => fails(r, /minimum deposit of 1 USDC/));

await check("shieldAndSend USDC private send, unfunded (relay lookup, no deposit)", "shieldAndSend", {
  rpcUrl,
  secret: b64(32),
  mint: USDC,
  amount: "1000000",
  recipientSolana: "11111111111111111111111111111112",
  resumeOnlyReason: "smoke: claim key unfunded",
}, (r) => fails(r, /smoke: claim key unfunded/));

await check("shieldAndSend USDC shielded, unfunded (relay lookup, no deposit)", "shieldAndSend", {
  rpcUrl,
  secret: b64(32),
  mint: USDC,
  amount: "1000000",
  recipientUtxoPubkey: fromClaim?.utxoPubkey,
  recipientViewingPubkey: fromClaim?.viewingPubkey,
  resumeOnlyReason: "smoke: claim key unfunded",
}, (r) => fails(r, /smoke: claim key unfunded/));

rows.push({
  check: "CSP allows everything the SDK fetched",
  result: cspViolations.length === 0 ? "PASS" : "FAIL",
  ms: 0,
  detail: cspViolations[0] ?? [...hosts].filter((h) => !h.startsWith("localhost")).sort().join(", "),
});

await browser.close();
server.close();

console.log(`Chromium ${version} | RPC ${rpcUrl === proxied ? `proxy -> ${hostOf(upstream)}` : hostOf(rpcUrl)}`);
console.table(rows);
const failed = rows.filter((r) => r.result !== "PASS").length;
console.log(failed === 0 ? "ALL PASS" : `${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
