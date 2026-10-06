#!/usr/bin/env python3
"""Minera um par de chaves Solana cujo endereço começa com um prefixo.

Exemplos:
  python3 scripts/vanity_address.py                      # "Deadman" ou "deadman"
  python3 scripts/vanity_address.py --ignore-case        # qualquer caixa: DeAdMaN...
  python3 scripts/vanity_address.py --prefix Dead        # teste rápido
  python3 scripts/vanity_address.py --workers 8 --out ~/deadman-keys

O resultado é salvo no formato do Solana CLI (array JSON de 64 bytes) em
<out>/<endereço>.json com permissão 600. A chave privada nunca é impressa.

Velocidade: usa PyNaCl (libsodium) se estiver instalado (pip install pynacl),
senão a biblioteca `cryptography`. Em vez de codificar cada chave em base58,
o script pré-calcula os intervalos numéricos de chaves públicas cujo base58
começa com o prefixo e só compara inteiros, então o custo por tentativa é
praticamente só a geração da chave.
"""

import argparse
import itertools
import json
import multiprocessing as mp
import os
import sys
import time

ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
INDEX = {c: i for i, c in enumerate(ALPHABET)}

try:
    from nacl.bindings import crypto_sign_seed_keypair

    def keypair(seed: bytes) -> bytes:
        return crypto_sign_seed_keypair(seed)[0]

    BACKEND = "pynacl"
except ImportError:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

    def keypair(seed: bytes) -> bytes:
        return Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(
            Encoding.Raw, PublicFormat.Raw
        )

    BACKEND = "cryptography"


def b58encode(data: bytes) -> str:
    n = int.from_bytes(data, "big")
    out = []
    while n:
        n, r = divmod(n, 58)
        out.append(ALPHABET[r])
    pad = len(data) - len(data.lstrip(b"\0"))
    return "1" * pad + "".join(reversed(out))


def ranges_for(prefix: str) -> list[tuple[int, int]]:
    """Intervalos [lo, hi) de inteiros de 32 bytes cujo base58 começa com
    `prefix`, para cada comprimento possível de endereço."""
    top = 1 << 256
    out = []
    for length in range(32, 46):
        rest = length - len(prefix)
        if rest < 0:
            continue
        value = 0
        for c in prefix:
            value = value * 58 + INDEX[c]
        lo = value * 58**rest
        hi = (value + 1) * 58**rest
        # Só conta se o número realmente tem `length` dígitos (sem zero à
        # esquerda, que viraria '1').
        lo = max(lo, 58 ** (length - 1))
        hi = min(hi, 58**length, top)
        if lo < hi:
            out.append((lo, hi))
    return out


def variants(prefix: str, ignore_case: bool) -> list[str]:
    if not ignore_case:
        return [prefix]
    options = []
    for c in prefix:
        opts = {x for x in (c.lower(), c.upper()) if x in INDEX}
        options.append(sorted(opts))
    return ["".join(p) for p in itertools.product(*options)]


def worker(ranges, counter, found, stop):
    batch = 0
    while not stop.is_set():
        seed = os.urandom(32)
        pub = keypair(seed)
        n = int.from_bytes(pub, "big")
        batch += 1
        for lo, hi in ranges:
            if lo <= n < hi:
                found.put(seed + pub)
                stop.set()
                break
        if batch == 2000:
            with counter.get_lock():
                counter.value += batch
            batch = 0


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--prefix", action="append",
                   help="prefixo desejado (pode repetir). Padrão: Deadman e deadman")
    p.add_argument("--ignore-case", action="store_true",
                   help="aceita qualquer combinação de maiúsculas/minúsculas")
    p.add_argument("--workers", type=int, default=os.cpu_count() or 1)
    p.add_argument("--out", default="vanity-keys",
                   help="pasta de saída (fora do git!)")
    args = p.parse_args()

    prefixes = args.prefix or ["Deadman", "deadman"]
    targets = sorted({v for pre in prefixes for v in variants(pre, args.ignore_case)})
    for t in targets:
        bad = [c for c in t if c not in INDEX]
        if bad:
            sys.exit(f"'{t}' tem caracteres fora do base58: {''.join(bad)} "
                     "(não existem 0, O, I e l)")
    ranges = [r for t in targets for r in ranges_for(t)]
    space = sum(hi - lo for lo, hi in ranges)
    expected = (1 << 256) / space

    print(f"backend {BACKEND}, {args.workers} processos, {len(targets)} variante(s): "
          f"{', '.join(targets[:6])}{' …' if len(targets) > 6 else ''}")
    print(f"tentativas esperadas: ~{expected:,.0f}")

    counter = mp.Value("Q", 0)
    found = mp.Queue()
    stop = mp.Event()
    procs = [mp.Process(target=worker, args=(ranges, counter, found, stop), daemon=True)
             for _ in range(args.workers)]
    for proc in procs:
        proc.start()

    start = time.time()
    try:
        while not stop.wait(5):
            tried = counter.value
            rate = tried / max(time.time() - start, 1e-9)
            eta = (expected - tried) / rate if rate else float("inf")
            print(f"\r{tried:,} tentativas, {rate:,.0f}/s, "
                  f"tempo esperado restante ~{eta / 3600:,.1f} h", end="", flush=True)
    except KeyboardInterrupt:
        stop.set()
        print("\ninterrompido")
        return

    keypair_bytes = found.get()
    address = b58encode(keypair_bytes[32:])
    os.makedirs(args.out, mode=0o700, exist_ok=True)
    path = os.path.join(args.out, f"{address}.json")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(list(keypair_bytes), f)
    print(f"\nencontrado: {address}\nsalvo em: {path} (permissão 600)")
    print(f"confira com: solana-keygen pubkey {path}")


if __name__ == "__main__":
    main()
