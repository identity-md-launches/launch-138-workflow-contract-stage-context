#!/usr/bin/env python3
"""Export the reviewed ABIs to docs/abi/<Contract>.json, or fail with --check if they differ. Needs Foundry only."""
import argparse
import json
from pathlib import Path
import subprocess

CONTRACTS = {
    "PVP": "src/PVP.sol",
    "PvPadHook": "src/PvPadHook.sol",
    "PvPad": "src/PvPad.sol",
    "PvPadFeeRouter": "src/PvPadFeeRouter.sol",
    "IBuyAndBurn": "src/PvPadFeeRouter.sol",
    "KingOfThePad": "src/KingOfThePad.sol",
    "WorkerSubsidy": "src/WorkerSubsidy.sol",
    "PvPadBurner": "src/PvPadBurner.sol",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if the checked-in files differ")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    for name, source in CONTRACTS.items():
        raw = subprocess.check_output(["forge", "inspect", f"{source}:{name}", "abi", "--json"], cwd=root)
        rendered = json.dumps(json.loads(raw), indent=2) + "\n"
        path = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not path.exists() or path.read_text() != rendered:
                raise SystemExit(f"ABI mismatch: {path}")
            print(f"{name}: checked")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(rendered)
            print(f"{name}: exported")


if __name__ == "__main__":
    main()
