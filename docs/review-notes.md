# Review notes

Author's notes for the independent adversarial reviewer. They are neither an audit nor a deployment
approval. Tests passing describe the tested behaviour; they do not establish that untested
behaviour is safe.

## What changed versus launch 137

The hook's constructor now takes only the PoolManager. The pad and PVP addresses arrive through a
one-shot `bind(pad, pvp)` that `PvPad.initialize` performs on the hook, after both contracts exist.
The token name is `Pepe Values Pepe` (the earlier repository had `Pepe Value Pepe`). The pad's fee
and the king's bump are constructor parameters with hard maxima (1000 bps and 10000 bps) instead
of constants, with the approved defaults 100 and 1000. The fee router's raw ETH sends ignore return
data. Everything else follows the reviewed 137 design.

## Trust boundaries

- **PoolManager.** Every hook callback checks `msg.sender == poolManager`; the pad's
  `unlockCallback` checks the same and additionally that a pad-initiated swap is in flight.
  `msg.sender` is never used as a user identity; `hookData` and `tx.origin` are ignored.
- **The pad.** Only the pad may initialize or swap on the canonical pool. Any other router, and
  any other pool key with this hook, is refused. A different pool with a different hook (or none)
  can always exist in a permissionless protocol; the fee guarantee is about this pool.
- **The hook** holds nothing, returns a zero `BeforeSwapDelta` and no fee override, and has no
  return-delta permissions, so there is no NoOp or custom-accounting surface. Liquidity add,
  remove and donate are not intercepted: LPs can always exit.
- **The bind.** Before binding, anyone can call `bind` from a contract that presents `poolManager()`,
  `token()` and `hook()` getters. That is the only power an outsider ever has over the hook, it is
  a griefing power (the real pad's `initialize` then reverts), it cannot touch funds, and it ends
  the moment the real pad binds. Mitigation and detection are in
  [deployment.md](deployment.md#the-bind-window). Rejected alternatives: a deployer-based
  authority would be either the public CREATE2 factory (no authority) or a placeholder in the
  constructor (forbidden); binding on first `beforeInitialize` has the same window.
- **Fee router.** Zero house cut is structural: there is no treasury address, no cut variable and
  no owner. Fees are credited to the beneficiary current at deposit time; delivery is a separate
  call so beneficiary code never runs inside a swap. Contract delivery is isolated in a self-call
  that reverts unless PVP supply fell, restoring the credit. The router verifies *that* supply fell,
  not the price paid; the supplied burner enforces a minimum rate and expiry, arbitrary
  beneficiaries enforce their own. A contract beneficiary that neither burns nor calls `withdraw`
  leaves its own fees stranded; nominate beneficiaries accordingly.
- **King.** No refunds, no expiry, no payout to the dethroned king, no admin. If WorkerSubsidy
  rejects the ETH the entire claim reverts. Bids near `uint256` overflow revert without state
  change.
- **WorkerSubsidy.** The contract verifies the updater and the Merkle proof. It cannot verify the
  oracle attestation, the worker data or the honesty of the updater. The two-step owner can
  rotate the updater; there is no owner withdrawal, sweep or pause. Renouncing ownership
  permanently disables rotation. A bad root makes one epoch unclaimable until it expires; the
  ETH then rolls forward.

## Assumptions

- The PoolManager at the constructor argument is the intended Uniswap v4 deployment on Sepolia.
  Code-length checks in constructors guard against typos, not provenance.
- PVP is a plain ERC-20 (it is: OpenZeppelin `ERC20` + `ERC20Burnable`, no hooks, no fees on
  transfer). The pad supports nothing else. ETH is native, not WETH.
- The launch factory is the token's immediate deployer and receives the whole supply.
- Beneficiary and payee callbacks are untrusted; every path that calls one either isolates it
  (`distribute`) or reverts the whole operation on failure (`sell`, `withdraw`, `claim`).
- Direct ETH forced into the pad or the hook (`SELFDESTRUCT` from elsewhere) is not recoverable and
  is not counted anywhere. The subsidy's budget snapshot counts all ETH it holds, however it
  arrived.

## Rounding

Pad fee rounds down (zero for inputs under 100 wei at 100 bps). King bump rounds up. Burner minimum
output rounds up. Zero-output trades revert.

## Local verification performed

- `forge build`, `forge test` (122 tests: unit, fuzz, and a stateful invariant with `fail_on_revert`
  against the real `PoolManager`), `forge fmt --check`, ABI export check, Python unit tests.
- The two admission floor suites supplied with the task (`Hook.protected.t.sol`,
  `Token.protected.t.sol`) were run from `test/scratch` against the built creation code with
  `IMD_HOOK_FLAGS=8320`, `IMD_POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` (code etched),
  `IMD_TOKEN_DECIMALS=18`: 9/9 pass. They also pass without `IMD_POOL_MANAGER`, since the hook's
  constructor does not call the manager.
- `Deployment.t.sol` deploys the exact manifest creation code (initcode + the Sepolia PoolManager
  word) at a mined address and walks the documented order end to end.

## Not done here, and needed before release

- Independent adversarial review of this source and of the generated manifest (a separate
  assignment).
- Fork rehearsal on Sepolia against the real PoolManager: initialize through the pad, seed, buy,
  sell, LP exit, king claim, fee delivery, epoch claim.
- Static analysis (Slither / Mythril), gas profiling of `beforeSwap` on the fork, and any external
  audit the risk score warrants. Score by the security reference: permissions 2 (two low/high
  gates, no deltas), external calls 2, state 1, upgrade 0, token handling 0 — "medium", so a
  professional review is recommended and the adversarial review step is mandatory in this workflow.
- Concrete values for every item in [deployment.md](deployment.md#parameters-the-services-must-choose-and-review).
