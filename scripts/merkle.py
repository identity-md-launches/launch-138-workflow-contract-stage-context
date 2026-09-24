#!/usr/bin/env python3
"""Offline WorkerSubsidy epoch builder. Standard library only; no network, no chain access.

Input: a JSON array of {"payee": "0x...", "amount": "<integer wei>"} entries.
Output: JSON with the epoch root, budget check and one proof per payee, ready for
`WorkerSubsidy.setEpoch(root, window)` and `WorkerSubsidy.claim(epoch, payee, amount, proof)`.

Leaf  = keccak256(keccak256(abi.encode(chainId, subsidy, epoch, payee, amount)))
Pairs = keccak256(min(a, b) || max(a, b)); an unpaired node is promoted unchanged.
Leaves are sorted before building so the same allocation always yields the same root.
"""
import argparse
import json
import re
import sys

# ---- keccak-256 (pure Python, so keepers need nothing beyond the interpreter) ----

_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_MASK = (1 << 64) - 1


def _rol(v, n):
    n %= 64
    return ((v << n) | (v >> (64 - n))) & _MASK if n else v


def _keccak_f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y] & _MASK) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    padded = bytearray(data) + b"\x01"
    while len(padded) % rate:
        padded.append(0)
    padded[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for offset in range(0, len(padded), rate):
        block = padded[offset : offset + rate]
        for i in range(rate // 8):
            a[i % 5][i // 5] ^= int.from_bytes(block[8 * i : 8 * i + 8], "little")
        a = _keccak_f(a)
    out = b"".join(a[x][y].to_bytes(8, "little") for y in range(5) for x in range(5))
    return out[:32]


# ---- encoding helpers ----


def _word(value: int) -> bytes:
    if value < 0 or value >= 1 << 256:
        raise ValueError("value out of uint256 range")
    return value.to_bytes(32, "big")


def parse_address(value: str) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", value):
        raise ValueError(f"not an address: {value!r}")
    n = int(value, 16)
    if n == 0:
        raise ValueError("zero address")
    return n


def leaf(chain_id: int, subsidy: int, epoch: int, payee: int, amount: int) -> bytes:
    inner = keccak256(_word(chain_id) + _word(subsidy) + _word(epoch) + _word(payee) + _word(amount))
    return keccak256(inner)


def hash_pair(a: bytes, b: bytes) -> bytes:
    return keccak256(a + b) if a < b else keccak256(b + a)


def build(leaves):
    """Returns (root, proofs) with proofs aligned to the given leaf order."""
    if not leaves:
        raise ValueError("no leaves")
    proofs = [[] for _ in leaves]
    level = list(leaves)
    positions = list(range(len(leaves)))  # leaf index -> position in current level
    while len(level) > 1:
        nxt = []
        for i in range(0, len(level), 2):
            nxt.append(hash_pair(level[i], level[i + 1]) if i + 1 < len(level) else level[i])
        for idx, pos in enumerate(positions):
            sib = pos ^ 1
            if sib < len(level):
                proofs[idx].append(level[sib])
            positions[idx] = pos // 2
        level = nxt
    return level[0], proofs


def verify(proof, root: bytes, node: bytes) -> bool:
    for sibling in proof:
        node = hash_pair(node, sibling)
    return node == root


def build_epoch(allocations, chain_id: int, subsidy: int, epoch: int, budget=None):
    seen = set()
    rows = []
    for entry in allocations:
        payee = parse_address(entry["payee"])
        amount = int(entry["amount"])
        if amount <= 0:
            raise ValueError(f"non-positive amount for {entry['payee']}")
        if payee in seen:
            raise ValueError(f"duplicate payee {entry['payee']}: aggregate entitlements first")
        seen.add(payee)
        rows.append((payee, amount))
    total = sum(a for _, a in rows)
    if budget is not None and total > budget:
        raise ValueError(f"allocations total {total} exceed budget {budget}")
    rows.sort(key=lambda r: leaf(chain_id, subsidy, epoch, r[0], r[1]))
    leaves = [leaf(chain_id, subsidy, epoch, p, a) for p, a in rows]
    root, proofs = build(leaves)
    for lf, pf in zip(leaves, proofs):
        assert verify(pf, root, lf)
    return {
        "chainId": chain_id,
        "subsidy": "0x%040x" % subsidy,
        "epoch": epoch,
        "root": "0x" + root.hex(),
        "total": str(total),
        "budget": None if budget is None else str(budget),
        "claims": [
            {"payee": "0x%040x" % p, "amount": str(a), "proof": ["0x" + h.hex() for h in pf]}
            for (p, a), pf in zip(rows, proofs)
        ],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("allocations", help="JSON file: [{\"payee\": \"0x..\", \"amount\": \"wei\"}, ...]")
    parser.add_argument("--subsidy", required=True, help="WorkerSubsidy address")
    parser.add_argument("--epoch", required=True, type=int, help="the epoch id that setEpoch will create (currentEpoch + 1)")
    parser.add_argument("--chain-id", type=int, default=11155111, help="default: Sepolia")
    parser.add_argument("--budget", type=int, default=None, help="the contract balance the epoch will snapshot, in wei")
    args = parser.parse_args(argv)
    with open(args.allocations) as fh:
        allocations = json.load(fh)
    result = build_epoch(allocations, args.chain_id, parse_address(args.subsidy), args.epoch, args.budget)
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
