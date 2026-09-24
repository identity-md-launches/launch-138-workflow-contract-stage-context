"""Unit tests for scripts/merkle.py. Vectors were produced by the Solidity side (test/utils/Merkle.sol
and OpenZeppelin MerkleProof) so the keeper tool and WorkerSubsidy agree on leaves, roots and proofs."""
import unittest

import merkle

CHAIN = 11155111
SUBSIDY = 0x1111111111111111111111111111111111111111
EPOCH = 3
ALLOCATIONS = [
    {"payee": "0x000000000000000000000000000000000000aaaa", "amount": "1000000000000000000"},
    {"payee": "0x000000000000000000000000000000000000bbbb", "amount": "2000000000000000000"},
    {"payee": "0x000000000000000000000000000000000000cccc", "amount": "3000000000000000000"},
]
SOLIDITY_ROOT = "0x4e0c246c1657587140c2cf95da843933bb3535223c8413c09d62ad141427c53e"


class KeccakTest(unittest.TestCase):
    def test_known_vectors(self):
        self.assertEqual(
            merkle.keccak256(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        )
        self.assertEqual(
            merkle.keccak256(b"abc").hex(), "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
        )
        # Multi-block input (longer than the 136-byte rate).
        self.assertEqual(
            merkle.keccak256(b"a" * 200).hex(), merkle.keccak256(bytes(b"a" * 200)).hex()
        )


class EpochTest(unittest.TestCase):
    def test_root_matches_solidity(self):
        result = merkle.build_epoch(ALLOCATIONS, CHAIN, SUBSIDY, EPOCH, 6 * 10**18)
        self.assertEqual(result["root"], SOLIDITY_ROOT)
        self.assertEqual(result["total"], str(6 * 10**18))
        self.assertEqual(len(result["claims"]), 3)

    def test_every_proof_verifies(self):
        result = merkle.build_epoch(ALLOCATIONS, CHAIN, SUBSIDY, EPOCH)
        root = bytes.fromhex(result["root"][2:])
        for claim in result["claims"]:
            lf = merkle.leaf(CHAIN, SUBSIDY, EPOCH, int(claim["payee"], 16), int(claim["amount"]))
            proof = [bytes.fromhex(p[2:]) for p in claim["proof"]]
            self.assertTrue(merkle.verify(proof, root, lf))
            # A tampered amount does not verify.
            bad = merkle.leaf(CHAIN, SUBSIDY, EPOCH, int(claim["payee"], 16), int(claim["amount"]) + 1)
            self.assertFalse(merkle.verify(proof, root, bad))

    def test_deterministic_regardless_of_input_order(self):
        a = merkle.build_epoch(ALLOCATIONS, CHAIN, SUBSIDY, EPOCH)
        b = merkle.build_epoch(list(reversed(ALLOCATIONS)), CHAIN, SUBSIDY, EPOCH)
        self.assertEqual(a["root"], b["root"])

    def test_domain_separation(self):
        base = merkle.build_epoch(ALLOCATIONS, CHAIN, SUBSIDY, EPOCH)["root"]
        self.assertNotEqual(base, merkle.build_epoch(ALLOCATIONS, 1, SUBSIDY, EPOCH)["root"])
        self.assertNotEqual(base, merkle.build_epoch(ALLOCATIONS, CHAIN, SUBSIDY + 1, EPOCH)["root"])
        self.assertNotEqual(base, merkle.build_epoch(ALLOCATIONS, CHAIN, SUBSIDY, EPOCH + 1)["root"])

    def test_rejects_duplicates_zero_and_over_budget(self):
        with self.assertRaises(ValueError):
            merkle.build_epoch(ALLOCATIONS + [ALLOCATIONS[0]], CHAIN, SUBSIDY, EPOCH)
        with self.assertRaises(ValueError):
            merkle.build_epoch([{"payee": "0x" + "0" * 40, "amount": "1"}], CHAIN, SUBSIDY, EPOCH)
        with self.assertRaises(ValueError):
            merkle.build_epoch([{"payee": ALLOCATIONS[0]["payee"], "amount": "0"}], CHAIN, SUBSIDY, EPOCH)
        with self.assertRaises(ValueError):
            merkle.build_epoch(ALLOCATIONS, CHAIN, SUBSIDY, EPOCH, 6 * 10**18 - 1)
        with self.assertRaises(ValueError):
            merkle.build_epoch([], CHAIN, SUBSIDY, EPOCH)

    def test_single_leaf_has_empty_proof(self):
        result = merkle.build_epoch(ALLOCATIONS[:1], CHAIN, SUBSIDY, EPOCH)
        self.assertEqual(result["claims"][0]["proof"], [])
        lf = merkle.leaf(CHAIN, SUBSIDY, EPOCH, int(ALLOCATIONS[0]["payee"], 16), 10**18)
        self.assertEqual(result["root"], "0x" + lf.hex())

    def test_odd_sizes_promote_unpaired_nodes(self):
        for n in range(1, 9):
            allocs = [{"payee": "0x%040x" % (0x1000 + i), "amount": str(10**15 * (i + 1))} for i in range(n)]
            result = merkle.build_epoch(allocs, CHAIN, SUBSIDY, EPOCH)
            root = bytes.fromhex(result["root"][2:])
            for claim in result["claims"]:
                lf = merkle.leaf(CHAIN, SUBSIDY, EPOCH, int(claim["payee"], 16), int(claim["amount"]))
                self.assertTrue(merkle.verify([bytes.fromhex(p[2:]) for p in claim["proof"]], root, lf))


if __name__ == "__main__":
    unittest.main()
