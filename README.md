# PvPad — PVP launch contracts for Sepolia

Contract contribution for the PvPad workflow: Sepolia only (`11155111`), site label `pvpad`. This
repository replaces the blocked launch 137. What broke that launch was a hook whose constructor
took the pad and token addresses, so its manifest had to carry `$pad` / `$token` placeholders. Here
the hook takes **only the PoolManager**; the pad and the PVP token are wired afterwards by a
one-shot `bind` that `PvPad.initialize` performs once both exist.

This repository delivers source, tests, vendored dependencies, ABI exports and offline operator
tooling. It does **not** contain `launch.json` (a separate manifest assignment writes it; see
[docs/manifest-notes.md](docs/manifest-notes.md)), does not broadcast transactions and holds no
keys. Publishing, attestation, admission, deployment and the website are later services.

## Running the checks

```
bash scripts/check.sh
```

That runs `forge build --offline`, `forge test --offline`, `forge fmt --check`, the ABI export
check and the Python unit tests for the keeper tooling. Requirements: Foundry with solc `0.8.26`
already installed, and Python 3. Everything Solidity imports is an ordinary file under `lib/`
(pinned in [docs/dependencies.json](docs/dependencies.json)); there are no submodules, no npm, no
FFI and no filesystem permissions. The compiler target is Cancun (v4 needs transient storage).

## Contracts

| Contract | Role | Authority |
| --- | --- | --- |
| `PVP` | ERC-20 "Pepe Values Pepe", symbol `PVP`, 18 decimals. Zero-argument constructor mints exactly `10^27` minor units (1,000,000,000 PVP) to `msg.sender`, the launch factory. Holder `burn` / `burnFrom` only. | None. No owner, mint, pause or proxy. |
| `PvPadHook` | Gate-only Uniswap v4 hook: `beforeInitialize` + `beforeSwap`. Constructor takes only the PoolManager. Once bound it accepts only the pad as `sender` and only the canonical ETH/PVP key. Liquidity and donate callbacks are not intercepted. | `bind(pad, pvp)`: one shot, callable only by the pad on itself. Nothing else. |
| `PvPad` | The immutable ETH/PVP market and the only router the pool accepts. `buy` / `sell` with a fixed pad fee (`feeBps`, default 100 = 1%) forwarded to the fee router. Holds nothing between calls. | Deployer calls `initialize(hook, sqrtPriceX96)` once. No fee setter, pause or upgrade. |
| `PvPadFeeRouter` | Credits every pad fee to the KingOfThePad beneficiary current at that moment. Anyone can `distribute`; an EOA gets ETH, a contract is offered `buyAndBurn` and must lower PVP supply, else the credit is restored and stays pullable via `withdraw`. | None. Zero house cut, no treasury, no owner. |
| `KingOfThePad` | `claim(beneficiary)` with `msg.value > claimPrice` crowns the caller and names the fee beneficiary (EOA, LP, contract). 100% of the claim goes to WorkerSubsidy; the previous king is never paid. Next price = bid + `bumpBps` (default 1000 = +10%), rounded up. | None. |
| `WorkerSubsidy` | Holds king claims. The `updater` opens Merkle epochs (`setEpoch(root, window)`) only after the off-chain Identity MD oracle attests the root. Workers (or relayers) claim with proofs. Unclaimed ETH rolls into the next epoch. | Two-step owner can rotate the updater. No withdrawal, sweep or pause. |
| `PvPadBurner` | Optional contract beneficiary: buys PVP through the pad with the fees it is delivered and burns everything it receives, subject to an operator-set minimum rate and expiry. | Two-step owner sets quotes and can pull its own router credit as ETH. |

ABIs: `docs/abi/<Contract>.json` (plus `IBuyAndBurn.json`, the contract-beneficiary interface).
Refresh with `python3 scripts/export-abi.py`, verify with `--check`.

## How the pieces fit

1. The factory deploys `PVP` and receives the whole `10^27`. The 10/80/10 split is the launch
   policy's business and is not encoded here.
2. `WorkerSubsidy(owner, updater)`, `KingOfThePad(subsidy, initialPrice, bumpBps)`,
   `PvPadFeeRouter(pvp, king)` and `PvPad(manager, pvp, router, feeBps)` are deployed in that order.
3. `PvPadHook(manager)` is deployed with CREATE2 at an address whose low 14 bits are exactly
   `0x2080` (`beforeInitialize` bit 13, `beforeSwap` bit 7). The creation code is the initcode plus
   one ABI word: the PoolManager. Nothing else is baked in.
4. The pad's deployer calls `PvPad.initialize(hook, sqrtPriceX96)`. In one transaction the pad
   records the hook, calls `hook.bind(pad, pvp)`, and calls `PoolManager.initialize` with the
   canonical key (currency0 = native ETH, currency1 = PVP, fee 3000, tickSpacing 60, hooks = hook).
   The hook's `beforeInitialize` accepts because `sender == pad`. **Nobody else can initialize this
   pool; a service that calls `PoolManager.initialize` directly will be refused.**
5. Liquidity is seeded through ordinary v4 tooling; the hook never gates liquidity.
6. Trading: users call `pad.buy` / `pad.sell`. The hook refuses every other router, so every swap
   on the canonical pool pays the pad fee. The pool's own 0.30% LP fee stays with LPs.

Economics, in one paragraph: there is no pump.fun-style house. The 1% pad fee goes to whoever the
current king named as beneficiary. Becoming king costs an ETH bid that goes entirely to Identity MD
workers through WorkerSubsidy, whose epochs the keeper publishes after oracle attestation. A
contract beneficiary (for example the burner, or an LP contract) can turn its fees into burned PVP.

## Documentation

- [docs/deployment.md](docs/deployment.md): constructor inputs, deployment order, parameters the
  services must choose, the bind front-running window and how to close it.
- [docs/keeper.md](docs/keeper.md): the WorkerSubsidy keeper recipe (`api.imd.fun/workers`, the
  worker collection, oracle attestation, `scripts/merkle.py`, `setEpoch`).
- [docs/review-notes.md](docs/review-notes.md): assumptions, trust boundaries, known limitations,
  and what the independent adversarial review still has to do.
- [docs/manifest-notes.md](docs/manifest-notes.md): what the separate `launch.json` assignment must
  and must not put in the manifest.

## Tests

`forge test` runs 122 tests in 8 suites (unit, fuzz and a stateful invariant), all against the real
`PoolManager` code: token supply and immutability, hook permissions/flags/opcode scan/caller
refusal/bind rules, market buys and sells with fee accounting, slippage, partial fills, reentrancy,
king pricing and funding, subsidy epochs and proofs, fee delivery to EOAs and contracts including
failure and rollback, and conservation of ETH in the router under random king changes and
deliveries. The two admission floor suites supplied with the task were run against the built
creation code (hook flags `8320`, Sepolia PoolManager etched, token decimals `18`): 9/9 pass. Tests
passing are not an audit; see the review notes.
