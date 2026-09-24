# Notes for the launch.json assignment

This repository does not contain `launch.json`; the separate manifest assignment writes it. These
are the facts it needs, taken from the source, so the manifest and the code cannot disagree. The
approved workflow's attestation rule is the reason the hook looks the way it does: **constructor
arguments must be literal addresses or integers**, never `$pad`, `$token`, `$pvp` or a sibling
contract's name.

| Field | Value | Where it comes from |
| --- | --- | --- |
| `kind` | `univ4_hook` | approved workflow |
| `hook.contract` | `PvPadHook` | `src/PvPadHook.sol` |
| `hook.constructorArgs` | exactly one entry: `"0xE03A1074c86CFeDd5C142C4F04F1a1536e203543"` (the Sepolia PoolManager) | the constructor's only parameter |
| `hook.permissions` | `["beforeInitialize", "beforeSwap"]` — flags `0x2080` = `8320` | `getHookPermissions()`; the constructor reverts at any other address |
| `token.contract` | `PVP` | `src/PVP.sol` |
| `token.name` / `symbol` / `decimals` | `Pepe Values Pepe` / `PVP` / `18` | the ERC-20 metadata |
| `pool.pairedCurrency` | `0x0000000000000000000000000000000000000000` (native ETH) | the hook accepts only `currency0 == address(0)` |
| `pool.fee` / `pool.tickSpacing` | `3000` / `60` | `PvPadHook.POOL_FEE` / `TICK_SPACING`; any other key is refused |
| `pool.initialPrice` | a manifest choice (sqrtPriceX96, decimal string) | not fixed by the workflow or the code |

Do not add `totalSupply` or allocation basis points: the policy owns 10/80/10, and the token mints
`10^27` unconditionally.

The `notes` may describe the wiring — `PvPad.initialize(hook, sqrtPriceX96)` calls
`hook.bind(pad, pvp)` and then `PoolManager.initialize` — but must not instruct anyone to
substitute the pad or token address into `constructorArgs`. They may also say that the pool
initialization in the `pool` section is performed by the pad, not by a direct `PoolManager.initialize`
call, because the hook only accepts the pad as `sender`.

The supporting contracts (`WorkerSubsidy`, `KingOfThePad`, `PvPadFeeRouter`, `PvPad`, optional
`PvPadBurner`) have no field in the `univ4_hook` schema. Their constructors and order are in
[deployment.md](deployment.md); the deploy service still creates and wires them.

Reference checks the manifest reviewer can reproduce offline: `forge inspect src/PvPadHook.sol:PvPadHook abi`
shows a single constructor input `manager`; `docs/abi/PvPadHook.json` is that ABI checked in.
