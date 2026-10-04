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

const VERSION = "deadman-cloak/2 sdk/0.2.5";
const PROGRAM_ID = cloak.CLOAK_PROGRAM_ID;
const RELAY_URL = cloak.CLOAK_PRODUCTION_RELAY_URL;
const SPEND_DOMAIN = "deadman/cloak/spend/v1";
const SALT_DOMAIN = "deadman/cloak/deposit-salt/v1";
const RECEIVE_DOMAIN = "deadman/cloak/receive/v1";
const USDC_MINT = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
const USDT_MINT = "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB";
const POOLS = {
  [cloak.NATIVE_SOL_MINT]: { symbol: "SOL", decimals: 9, minDeposit: 10000000n, exitFixedFee: 5000000n },
  [USDC_MINT]: { symbol: "USDC", decimals: 6, minDeposit: 1000000n, exitFixedFee: 450000n },
  [USDT_MINT]: { symbol: "USDT", decimals: 6, minDeposit: 1000000n, exitFixedFee: 450000n },
};
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

function toBase64(bytes) {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
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

function claimSeed(secret) {
  if (secret.length !== 64 && secret.length !== 32) throw new Error("claim secret must be 32 or 64 bytes");
  return secret.slice(0, 32);
}

function poolMint(mint) {
  const m = mint ? cloak.address(mint) : cloak.NATIVE_SOL_MINT;
  if (!POOLS[m]) throw new Error(`No Cloak pool for mint ${m}`);
  return m;
}

const formatUnits = (v, pool) => `${Number(v) / 10 ** pool.decimals} ${pool.symbol}`;

function assertMinDeposit(mint, amount) {
  const pool = POOLS[mint];
  if (amount < pool.minDeposit) {
    throw new Error(`Below Cloak minimum deposit of ${formatUnits(pool.minDeposit, pool)} (got ${formatUnits(amount, pool)})`);
  }
}

const exitFee = (mint, amount) => POOLS[mint].exitFixedFee + (amount * 3n) / 1000n;

// The claim key's own Cloak identity. Deterministic, so a crash between the
// deposit and the send is recoverable from the claim key alone.
async function claimIdentity(secretB64) {
  const secret = fromBase64(secretB64);
  const seed = claimSeed(secret);
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

const commitmentValue = (c) => BigInt("0x" + String(c).replace(/^0x/, ""));

async function leafIndexes(mint) {
  const entries = await cloak.fetchCommitments(RELAY_URL, { mint });
  return new Map(entries.map((e) => [commitmentValue(e.commitment), Number(e.index)]));
}

async function findLeafIndex(commitment, mint) {
  return (await leafIndexes(mint)).get(commitment);
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
  const mint = poolMint(p.mint);
  const amount = BigInt(p.amount);
  assertMinDeposit(mint, amount);
  if (p.recipientSolana && amount <= exitFee(mint, amount)) {
    throw new Error(`Amount does not cover the Cloak exit fee of ${formatUnits(exitFee(mint, amount), POOLS[mint])}`);
  }
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

// A Cloak receiving identity. From `spendKey` (32 bytes) as given, or from
// the claim key's `secret`, so a beneficiary's phrase-derived claim key also
// owns the shielded notes paid to its receive address.
async function receiverIdentity(p) {
  const skSpend = p.secret
    ? sha256(concat(utf8(RECEIVE_DOMAIN), claimSeed(fromBase64(p.secret))))
    : fromBase64(p.spendKey ?? "");
  if (skSpend.length !== 32) throw new Error("spend key must be 32 bytes");
  const keypair = await cloak.deriveUtxoKeypairFromSpendKey(skSpend);
  const nk = cloak.getNkFromUtxoPrivateKey(keypair.privateKey);
  return { keypair, nk, viewingPubkey: cloak.deriveViewingKeyFromNk(nk).publicKey };
}

async function receiveAddress(p) {
  const id = await receiverIdentity(p);
  return {
    utxoPubkey: id.keypair.publicKey.toString(16).padStart(64, "0"),
    viewingPubkey: toHex(id.viewingPubkey),
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// @solana/kit's minified errors carry the HTTP status only in `context`.
function isTransient(e) {
  const status = e?.context?.statusCode;
  if (typeof status === "number") return status === 429 || status >= 500;
  return /429|Too Many Requests|fetch failed|Failed to fetch/i.test(e instanceof Error ? e.message : String(e));
}

// The SDK's delivery scan skips any record it fails to read, and its retry
// does not recognise @solana/kit's 429 message, so a rate-limited RPC hides
// notes silently. Retry the scan's reads here and record what still fails.
function scanRpc(connection, failures) {
  return new Proxy(connection, {
    get(target, prop, receiver) {
      const method = Reflect.get(target, prop, receiver);
      if (prop !== "getTransaction" && prop !== "getSignaturesForAddress") return method;
      return (...args) => {
        const request = method.apply(target, args);
        return {
          send: async (...sendArgs) => {
            for (let attempt = 0; ; attempt++) {
              try {
                return await request.send(...sendArgs);
              } catch (e) {
                if (attempt >= 6 || !isTransient(e)) {
                  failures.push(e);
                  throw e;
                }
                await sleep(500 * 2 ** attempt);
              }
            }
          },
        };
      };
    },
  });
}

const publicMint = (mint) => (mint === cloak.NATIVE_SOL_MINT ? null : mint);

// Notes sent to this identity by shielded transfers: trial-opens every
// delivery envelope on chain with the viewing key, keeps those whose
// commitment recomputes for this owner, then asks the relay for each note's
// leaf and the chain for its nullifier to tell spent from unspent.
async function scanReceived(p) {
  const connection = cloak.createCloakRpc(p.rpcUrl);
  const id = await receiverIdentity(p);
  // The SDK treats a failed or empty history read as "no deliveries"; some
  // RPCs serve no history for the registry at all, so check it explicitly.
  const registry = await cloak.getDeliveryRegistryPDA(PROGRAM_ID);
  const head = await cloak.fetchSignaturesForAddress(connection, registry, { limit: 1 });
  if (head.length === 0) {
    throw new Error("RPC returned no history for the Cloak delivery registry; use an RPC that serves getSignaturesForAddress");
  }
  const failures = [];
  const { notes, rpcCalls } = await cloak.scanRecipientDeliveryNotes({
    connection: scanRpc(connection, failures),
    programId: PROGRAM_ID,
    viewingKeyNk: id.nk,
    ownerUtxoPublicKey: id.keypair.publicKey,
    mints: Object.keys(POOLS).map((m) => cloak.address(m)),
  });
  if (failures.length > 0) {
    const e = new Error(`Scan incomplete: ${failures.length} delivery records could not be read (${failures[0]?.message ?? failures[0]}); try again`);
    e.retryable = true;
    throw e;
  }
  const unique = [...new Map(notes.filter((n) => n.commitmentVerified).map((n) => [n.commitment, n])).values()];
  const indexes = {};
  const utxos = [];
  for (const n of unique) {
    indexes[n.mint] ??= await leafIndexes(n.mint);
    const commitment = commitmentValue(n.commitment);
    utxos.push({
      amount: n.amount,
      keypair: id.keypair,
      blinding: n.blinding,
      mintAddress: n.mint,
      commitment,
      index: indexes[n.mint].get(commitment),
    });
  }
  const { spent } = await cloak.verifyUtxos(
    utxos.filter((u) => u.index !== undefined),
    connection,
    PROGRAM_ID,
  );
  return {
    rpcCalls: rpcCalls + 1,
    notes: utxos.map((u, i) => ({
      commitment: u.commitment.toString(16).padStart(64, "0"),
      amount: u.amount.toString(),
      mint: publicMint(u.mintAddress),
      blinding: u.blinding.toString(16).padStart(64, "0"),
      index: u.index ?? null,
      spent: spent.includes(u),
      blockTime: unique[i].blockTime ?? null,
    })),
  };
}

// Unshields received notes of one mint, in full, to a public address. The
// relay submits it; the claim key only authenticates to the relay and pays
// nothing. Exit fee 0.3% + fixed, deducted from the notes.
async function withdrawReceived(p) {
  if (!Array.isArray(p.notes) || p.notes.length === 0) throw new Error("No notes to withdraw");
  const connection = cloak.createCloakRpc(p.rpcUrl);
  const claim = await claimIdentity(p.secret);
  const id = await receiverIdentity(p);
  const mint = poolMint(p.notes[0].mint);
  const destination = cloak.address(p.destination);
  const utxos = [];
  for (const n of p.notes) {
    if (poolMint(n.mint) !== mint) throw new Error("Withdraw one mint at a time");
    const utxo = { amount: BigInt(n.amount), keypair: id.keypair, blinding: commitmentValue(n.blinding), mintAddress: mint };
    utxo.commitment = await cloak.computeUtxoCommitment(utxo);
    if (utxo.commitment !== commitmentValue(n.commitment)) throw new Error("Note does not belong to this claim key");
    utxos.push(utxo);
  }
  const indexes = await leafIndexes(mint);
  for (const utxo of utxos) {
    utxo.index = indexes.get(utxo.commitment);
    if (utxo.index === undefined) throw new Error("Note is not indexed by the Cloak relay yet; try again shortly");
  }
  const { spent } = await cloak.verifyUtxos(utxos, connection, PROGRAM_ID);
  if (spent.length > 0) throw new Error(`${spent.length} of these notes were already withdrawn`);
  const total = utxos.reduce((sum, u) => sum + u.amount, 0n);
  if (total <= exitFee(mint, total)) {
    throw new Error(`Notes do not cover the Cloak exit fee of ${formatUnits(exitFee(mint, total), POOLS[mint])}`);
  }
  const res = await cloak.fullWithdraw(utxos, destination, {
    connection,
    programId: PROGRAM_ID,
    relayUrl: RELAY_URL,
    depositorKeypair: claim.signer,
    walletPublicKey: claim.signer.address,
    chainNoteViewingKeyNk: id.nk,
  });
  return { signature: res.signature, amount: total.toString(), fee: exitFee(mint, total).toString() };
}

// On-device check of the whole deposit pipeline (circuit download and digest
// check, witness, Groth16 proof, risk quote, transaction build). Stops right
// before signing: nothing is signed, sent or registered.
async function dryRunDeposit(p) {
  const connection = cloak.createCloakRpc(p.rpcUrl);
  const id = await claimIdentity(p.secret);
  const mint = poolMint(p.mint);
  const amount = BigInt(p.amount);
  assertMinDeposit(mint, amount);
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
        relaySupplementalAlt: mint !== cloak.NATIVE_SOL_MINT,
        onProgress: (m) => steps.push([Date.now() - t0, String(m)]),
        onTransactProofBuilt: async () => {
          throw stop;
        },
      },
    );
  } catch (e) {
    if (e !== stop && !(e instanceof Error && e.message.includes("dry run stop"))) throw e;
    const at = (prefix) => steps.find(([, m]) => m.startsWith(prefix))?.[0];
    const proveStart = at("Generating ZK proof");
    const proveEnd = at("Converting proof to bytes");
    return {
      reachedSigning: true,
      ms: Date.now() - t0,
      proveMs: proveStart !== undefined && proveEnd !== undefined ? proveEnd - proveStart : null,
      depositor: id.signer.address,
      steps: steps.map(([ms, m]) => `${ms}ms ${m}`),
    };
  }
  throw new Error("dry run reached submission");
}

// dryRunDeposit from a random, unfunded key: proves the device can run
// Cloak end to end against mainnet without holding or moving any funds.
async function selfTest(p) {
  const t0 = Date.now();
  await cloak.loadVerifiedCircuitArtifacts(cloak.getCircuitsPath());
  const downloadMs = Date.now() - t0;
  const mint = poolMint(p.mint);
  const dry = await dryRunDeposit({
    rpcUrl: p.rpcUrl,
    secret: toBase64(crypto.getRandomValues(new Uint8Array(32))),
    mint: p.mint ?? null,
    amount: String(p.amount ?? POOLS[mint].minDeposit),
  });
  return {
    reachedSigning: dry.reachedSigning,
    downloadMs,
    proveMs: dry.proveMs,
    totalMs: Date.now() - t0,
    depositor: dry.depositor,
    steps: dry.steps,
  };
}

const ops = {
  shieldAndSend,
  receiveAddress,
  scanReceived,
  withdrawReceived,
  dryRunDeposit,
  selfTest,
  ping: async () => ({ version: VERSION }),
};

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
