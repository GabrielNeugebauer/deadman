// Deadman <-> Cloak bridge, run inside a headless Android WebView.
//
// Dart calls `window.deadmanCloak.run(op, payloadJson)` through
// `callAsyncJavaScript` and gets a JSON string back. Secrets arrive as
// arguments of that call, live only in this page's memory and are never sent
// anywhere: the SDK sends proofs, public keys and signatures, not keys.
import { install as installEd25519 } from "@solana/webcrypto-ed25519-polyfill";
import { sha256 } from "@noble/hashes/sha2";
import * as cloak from "@cloak.dev/sdk";

installEd25519();

const VERSION = "deadman-cloak/1 sdk/0.2.5";
const PROGRAM_ID = cloak.CLOAK_PROGRAM_ID;
const RELAY_URL = cloak.CLOAK_PRODUCTION_RELAY_URL;
const SPEND_DOMAIN = "deadman/cloak/spend/v1";
const SALT_DOMAIN = "deadman/cloak/deposit-salt/v1";
const FIELD_MODULUS =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

const utf8 = (s) => new TextEncoder().encode(s);

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

function fromBase64(s) {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function fromHex(hex, len, label) {
  const clean = hex.replace(/^0x/, "");
  if (!/^[0-9a-fA-F]+$/.test(clean) || clean.length !== len * 2) {
    throw new Error(`${label} must be ${len} bytes of hex`);
  }
  const out = new Uint8Array(len);
  for (let i = 0; i < len; i++) out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  return out;
}

const toHex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

function bytesToBigint(bytes) {
  let v = 0n;
  for (const b of bytes) v = (v << 8n) | BigInt(b);
  return v;
}

// The claim key's own Cloak identity. Deterministic, so a crash between the
// deposit and the send is recoverable from the claim key alone.
async function claimIdentity(secretB64) {
  const secret = fromBase64(secretB64);
  if (secret.length !== 64 && secret.length !== 32) throw new Error("claim secret must be 32 or 64 bytes");
  const seed = secret.slice(0, 32);
  const signer = await cloak.signerFromSecretKey(secret);
  const skSpend = sha256(concat(utf8(SPEND_DOMAIN), seed));
  const nk = cloak.expandSpendKey(skSpend).nsk;
  return { signer, seed, nk };
}

// 96-bit note salt bound to (claim key, mint, amount): the deposit note and
// its commitment can be recomputed later without scanning the chain.
function depositSalt(seed, mint, amount) {
  const h = sha256(concat(utf8(SALT_DOMAIN), seed, utf8(mint), utf8(amount.toString())));
  const v = bytesToBigint(h.slice(0, 12));
  return v === 0n ? 1n : v;
}

async function findLeafIndex(commitment, mint) {
  const entries = await cloak.fetchCommitments(RELAY_URL, { mint });
  const hit = entries.find((e) => BigInt("0x" + String(e.commitment).replace(/^0x/, "")) === commitment);
  return hit?.index;
}

function parseRecipient(utxoPubkeyHex, viewingPubkeyHex) {
  const utxoPubkey = bytesToBigint(fromHex(utxoPubkeyHex, 32, "recipient Cloak pubkey"));
  if (utxoPubkey === 0n || utxoPubkey >= FIELD_MODULUS) throw new Error("recipient Cloak pubkey is not a field element");
  return { utxoPubkey, viewingPubkey: fromHex(viewingPubkeyHex, 32, "recipient viewing key") };
}

// Claim key -> Cloak pool -> recipient.
//
// 1. Deposit `amount` from the claim key into a note owned by the claim key's
//    Cloak identity (wallet-signed, straight to chain, no protocol fee).
// 2a. Shielded transfer of that whole note to the recipient's Cloak pubkey,
//     with a delivery envelope sealed to their viewing key (submitted through
//     the Cloak relay, authenticated by the claim key, no protocol fee), or
// 2b. with `recipientSolana`, a withdrawal of the whole note to that public
//     address (Cloak's "private send"; exit fee 0.3% + fixed).
// Re-running after a partial failure skips a deposit that already landed.
async function shieldAndSend(p) {
  const connection = cloak.createCloakRpc(p.rpcUrl);
  const id = await claimIdentity(p.secret);
  const mint = p.mint ? cloak.address(p.mint) : cloak.NATIVE_SOL_MINT;
  const amount = BigInt(p.amount);
  const recipient = p.recipientSolana ? null : parseRecipient(p.recipientUtxoPubkey, p.recipientViewingPubkey);
  const salt = depositSalt(id.seed, mint, amount);
  const { utxo } = await cloak.createRecoverableDepositUtxo(amount, id.nk, mint, salt);

  let note;
  let merkleTree;
  let depositSignature = null;
  const existing = await findLeafIndex(utxo.commitment, mint);
  if (existing === undefined) {
    if (p.resumeOnlyReason) throw new Error(p.resumeOnlyReason);
    const res = await cloak.transact(
      {
        inputUtxos: [await cloak.createZeroUtxo(mint)],
        outputUtxos: [utxo],
        externalAmount: amount,
        depositor: id.signer.address,
      },
      {
        connection,
        programId: PROGRAM_ID,
        relayUrl: RELAY_URL,
        depositorKeypair: id.signer,
        chainNoteViewingKeyNk: id.nk,
        chainNoteSalt: salt,
        relaySupplementalAlt: mint !== cloak.NATIVE_SOL_MINT,
      },
    );
    note = res.outputUtxos[0];
    merkleTree = res.merkleTree;
    depositSignature = res.signature;
  } else {
    note = { ...utxo, index: Number(existing) };
    const { spent } = await cloak.verifyUtxos([note], connection, PROGRAM_ID);
    if (spent.length > 0) {
      return { state: "already_sent", depositSignature, sendSignature: null, commitment: utxo.commitment.toString(16) };
    }
  }

  const options = {
    connection,
    programId: PROGRAM_ID,
    relayUrl: RELAY_URL,
    depositorKeypair: id.signer,
    walletPublicKey: id.signer.address,
    chainNoteViewingKeyNk: id.nk,
    cachedMerkleTree: merkleTree,
  };
  const sent = recipient
    ? await cloak.transfer([note], recipient.utxoPubkey, note.amount, {
        ...options,
        recipientViewingPublicKey: recipient.viewingPubkey,
      })
    : await cloak.fullWithdraw([note], cloak.address(p.recipientSolana), options);
  return {
    state: "sent",
    depositSignature,
    sendSignature: sent.signature,
    commitment: utxo.commitment.toString(16),
  };
}

// Receive address for a Cloak spend key held by the beneficiary's app.
async function receiveAddress(p) {
  const skSpend = fromBase64(p.spendKey);
  if (skSpend.length !== 32) throw new Error("spend key must be 32 bytes");
  const kp = await cloak.deriveUtxoKeypairFromSpendKey(skSpend);
  const nk = cloak.getNkFromUtxoPrivateKey(kp.privateKey);
  const vk = cloak.deriveViewingKeyFromNk(nk);
  return {
    utxoPubkey: kp.publicKey.toString(16).padStart(64, "0"),
    viewingPubkey: toHex(vk.publicKey),
  };
}

// On-device check of the whole deposit pipeline (circuit download and digest
// check, witness, Groth16 proof, risk quote, transaction build). Stops right
// before signing: nothing is signed, sent or registered.
async function dryRunDeposit(p) {
  const connection = cloak.createCloakRpc(p.rpcUrl);
  const id = await claimIdentity(p.secret);
  const mint = p.mint ? cloak.address(p.mint) : cloak.NATIVE_SOL_MINT;
  const amount = BigInt(p.amount);
  const salt = depositSalt(id.seed, mint, amount);
  const { utxo } = await cloak.createRecoverableDepositUtxo(amount, id.nk, mint, salt);
  const t0 = Date.now();
  const steps = [];
  const stop = new Error("dry run stop");
  try {
    await cloak.transact(
      {
        inputUtxos: [await cloak.createZeroUtxo(mint)],
        outputUtxos: [utxo],
        externalAmount: amount,
        depositor: id.signer.address,
      },
      {
        connection,
        programId: PROGRAM_ID,
        relayUrl: RELAY_URL,
        depositorKeypair: id.signer,
        chainNoteViewingKeyNk: id.nk,
        chainNoteSalt: salt,
        enforceViewingKeyRegistration: false,
        onProgress: (m) => steps.push(`${Date.now() - t0}ms ${m}`),
        onTransactProofBuilt: async () => {
          throw stop;
        },
      },
    );
  } catch (e) {
    if (e !== stop && !(e instanceof Error && e.message.includes("dry run stop"))) throw e;
    return { reachedSigning: true, ms: Date.now() - t0, depositor: id.signer.address, steps };
  }
  throw new Error("dry run reached submission");
}

const ops = { shieldAndSend, receiveAddress, dryRunDeposit, ping: async () => ({ version: VERSION }) };

async function run(op, payloadJson) {
  const fn = ops[op];
  if (!fn) return JSON.stringify({ ok: false, error: `unknown op ${op}` });
  try {
    const result = await fn(JSON.parse(payloadJson));
    return JSON.stringify({ ok: true, result });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return JSON.stringify({
      ok: false,
      error: message,
      category: e?.category ?? null,
      retryable: e?.retryable ?? null,
    });
  }
}

globalThis.deadmanCloak = { version: VERSION, run };
