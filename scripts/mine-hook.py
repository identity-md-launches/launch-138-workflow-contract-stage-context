#!/usr/bin/env python3
"""Offline CREATE2 salt mining for PvPadHook. Prints an address and salt; deploys nothing, contacts no chain.

The hook's creation code is its initcode followed by exactly one ABI word: the PoolManager address.
The mined address must carry exactly the beforeInitialize|beforeSwap bits (0x2080 under mask 0x3fff).
"""
import argparse
from pathlib import Path
import re
import subprocess

FLAGS = 0x2080
MASK = 0x3FFF


def address_arg(value):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value) or int(value, 16) == 0:
        raise argparse.ArgumentTypeError("must be a nonzero address")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manager", type=address_arg, required=True, help="the v4 PoolManager (the only constructor argument)")
    parser.add_argument("--deployer", type=address_arg, required=True, help="the contract that executes CREATE2")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    bytecode = subprocess.check_output(
        ["forge", "inspect", "src/PvPadHook.sol:PvPadHook", "bytecode"], cwd=root, text=True
    ).strip()
    init_code = bytecode + args.manager[2:].lower().zfill(64)
    # `cast create2` matches a hex suffix; a 16-bit suffix of 2080 fixes the 14 permission bits exactly.
    out = subprocess.check_output(
        ["cast", "create2", "--deployer", args.deployer, "--init-code", init_code, "--ends-with", "2080", "--no-random"],
        cwd=root,
        text=True,
    )
    print(out.strip())
    match = re.search(r"Address:\s*(0x[0-9a-fA-F]{40})", out)
    if match:
        found = int(match.group(1), 16) & MASK
        assert found == FLAGS, f"mined address carries flags {found:#x}, expected {FLAGS:#x}"
        print(f"flags ok: {found:#x}")


if __name__ == "__main__":
    main()
