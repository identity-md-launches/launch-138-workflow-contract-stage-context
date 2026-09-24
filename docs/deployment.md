# Deployment handoff (unsigned)

Sepolia only, chain ID `11155111`. Nothing here is a transaction, a key or an RPC endpoint. The
services check the chain ID and the code at every dependency address before broadcasting. Bytecode
portability is not authorization to deploy elsewhere.

## Toolchain

Solidity `0.8.26`, EVM `cancun`, optimizer on with 200 runs, `via_ir = false`, `bytecode_hash =
"none"`, `cbor_metadata = false`, exactly as in `foundry.toml`. These settings are part of the
attested creation code and therefore of the hook's CREATE2 address. Install the native solc in the
offline profile; do not swap in a wrapper or enable FFI / filesystem access.

## Constructor inputs

| Artifact | Constructor inputs, in order | Constraints and defaults |
| --- | --- | --- |
| `src/PVP.sol:PVP` | none | Must be deployed by the factory: it mints `10^27` to `msg.sender` and the factory must end up holding all of it. Name `Pepe Values Pepe`, symbol `PVP`, 18 decimals. |
| `src/WorkerSubsidy.sol:WorkerSubsidy` | `address initialOwner`, `address initialUpdater` | Both nonzero (OpenZeppelin `Ownable` rejects a zero owner). Owner rotates the updater and is two-step. |
| `src/KingOfThePad.sol:KingOfThePad` | `address payable subsidy`, `uint256 initialPrice`, `uint256 bump` | `subsidy` must have code; `initialPrice > 0` wei; `bump <= 10000`. Approved default bump is `1000`. Tests use `0.01 ether` as the initial price; the real value is a deployment choice. |
| `src/PvPadFeeRouter.sol:PvPadFeeRouter` | `PVP pvp`, `KingOfThePad kingContract` | Both must have code. Immutable. |
| `src/PvPad.sol:PvPad` | `IPoolManager manager`, `IERC20 pvp`, `PvPadFeeRouter router`, `uint256 padFeeBps` | All three addresses must have code and `router.token() == pvp`; `padFeeBps <= 1000`. Approved default is `100`. The immediate deployer becomes `configurator`, the only address that may call `initialize`, once. |
| `src/PvPadHook.sol:PvPadHook` | `IPoolManager manager` | **The only argument.** Nonzero. Deployed with CREATE2 at an address whose low 14 bits are exactly `0x2080` (decimal `8320`); the constructor reverts otherwise. |
| `src/PvPadBurner.sol:PvPadBurner` | `PvPad market`, `address operator` | Optional. `market` must have code; `operator` is the two-step owner. Starts with no quote. |

Sepolia PoolManager named by the approved workflow: `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`.

## Order

1. **PVP** by the factory. Confirm `totalSupply() == balanceOf(factory) == 10^27`, decimals 18.
   The 10/80/10 allocation is the launch policy's; this repository does not encode it and the
   manifest must not carry supply or allocation fields.
2. **WorkerSubsidy**, then **KingOfThePad** with that subsidy, then **PvPadFeeRouter** with PVP and
   the king, then **PvPad** with the PoolManager, PVP, the router and `feeBps`. Whoever deploys the
   pad must be able to send one more transaction from the same address (step 4).
3. **PvPadHook** with the PoolManager only, via CREATE2 from a contract the service controls.
   Offline salt mining: `python3 scripts/mine-hook.py --manager 0xE03A…3543 --deployer <create2 contract>`
   (wraps `cast create2 --ends-with 2080`, which fixes the required 14 bits). The salt depends on
   the deployer address and the creation code, nothing else. Verify on chain:
   `poolManager() == manager`, `pad() == 0`, `token() == 0`, `getHookPermissions()` = beforeInitialize +
   beforeSwap, `uint160(hook) & 0x3fff == 0x2080`, runtime code equals the attested artifact.
4. **`PvPad.initialize(hook, sqrtPriceX96)`** from the pad's configurator. Atomically: records the
   hook, calls `hook.bind(pad, pvp)` (the hook checks `msg.sender == pad`, `pad.hook() == hook`,
   `pad.poolManager() == manager`, `pad.token() == pvp`), and calls `PoolManager.initialize` with
   the canonical key. A wrong price reverts through the PoolManager and the bind is rolled back
   with it. After success `hook.pad()`, `hook.token()` and `pad.hook()` are final.
   **Do not call `PoolManager.initialize` from the service directly**: the hook only accepts the pad
   as `sender`, so the manifest's `pool` section is realised by this call.
5. **Seed liquidity** with ordinary v4 tooling (the hook never intercepts liquidity). The pad holds
   no liquidity and no positions. Price convention: `sqrtPriceX96 = sqrt(PVP minor units per wei) * 2^96`;
   both assets have 18 decimals. The fixture price in tests is 1:1, a fixture and not a recommendation.
6. Optionally deploy **PvPadBurner**, have its operator call `setQuote(minTokensPerEth, validUntil)`,
   and nominate it as beneficiary in a king claim.
7. Re-read every getter (`docs/abi/*.json`) and hand the live addresses of PVP, KingOfThePad,
   WorkerSubsidy, PvPadFeeRouter, PvPad and PvPadHook to the frontend with explorer links.

## The bind window

Between step 3 and step 4 the hook is deployed but unbound, and `bind` is callable by any contract
that presents itself as a pad (the hook has no other root of trust: its constructor knows only the
PoolManager, by design). A griefer who binds first makes step 4 revert with `AlreadyBound`. This
cannot move funds or affect an already-bound hook; it only costs a redeploy. Close the window:

- Perform steps 3 and 4 in the **same transaction** (a small deployer contract that does the
  CREATE2 and then calls `pad.initialize`), or submit step 4 immediately after step 3 through a
  private relay. The constructor args in the manifest do not change if a new salt is needed.
- Before seeding liquidity, verify `hook.pad() == pad` and `hook.token() == PVP`. If not, mine a new
  salt, redeploy the hook and repeat step 4; the old hook is inert.

## Parameters the services must choose and review

- Initial king price (wei) and, if different from 1000, the bump.
- Pad fee bps, if different from 100.
- WorkerSubsidy owner and updater identities; the oracle client integration behind the updater.
- Initial `sqrtPriceX96`, liquidity amount, range and the LP controller.
- The CREATE2 deployer contract and the mined salt.
- Whether to deploy the burner, its operator, and its quote policy.

## Frontend and keeper integration

- King: read `king`, `beneficiary`, `claimPrice`; call `claim(beneficiary)` with strictly more than
  `claimPrice`. Concurrent claims can invalidate a stale bid.
- Trading: quote off chain, then `buy(minPvpOut, deadline, recipient)` with gross ETH, or approve
  PVP to the pad and `sell(pvpIn, minEthOut, deadline, recipient)`. Limits are on the amount
  delivered after the pad fee. Partial fills, failed payments and any bad settlement revert.
- Fees: index `FeesCredited`, `FeesDelivered`, `DeliveryDeferred`, `Withdrawn`; `pending(addr)` is
  authoritative. Anyone may call `assignUnassigned()` once a king exists and `distribute(beneficiary,
  executionGas)`; size `executionGas` for the beneficiary's own logic (a burner buy needs several
  hundred thousand). Too little gas defers the delivery and preserves the credit.
- Workers: poll `currentEpoch`, `epochs(id)` and the published proofs; call `claim(id, payee,
  amount, proof)` before `endsAt`. A funded subsidy does not mean a currently claimable epoch.
