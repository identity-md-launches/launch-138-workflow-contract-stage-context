// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PVP} from "../../src/PVP.sol";
import {PvPad} from "../../src/PvPad.sol";
import {PvPadHook} from "../../src/PvPadHook.sol";
import {PvPadFeeRouter} from "../../src/PvPadFeeRouter.sol";
import {KingOfThePad} from "../../src/KingOfThePad.sol";
import {WorkerSubsidy} from "../../src/WorkerSubsidy.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {LiquidityDriver} from "../mocks/LiquidityDriver.sol";

/// @dev Deploys the whole PvPad system against a local PoolManager, in the documented order, and
/// seeds the canonical pool. Every test suite builds on this so the wiring under test is the real one.
abstract contract Fixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant HOOK_FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP;
    uint256 internal constant INITIAL_CLAIM_PRICE = 0.01 ether;
    uint256 internal constant BUMP_BPS = 1000;
    uint256 internal constant FEE_BPS = 100;
    int256 internal constant SEED_LIQUIDITY = 1_000 ether;

    address internal owner = makeAddr("owner");
    address internal updater = makeAddr("updater");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    PoolManager internal manager;
    PVP internal pvp;
    WorkerSubsidy internal subsidy;
    KingOfThePad internal king;
    PvPadFeeRouter internal router;
    PvPad internal pad;
    PvPadHook internal hook;
    LiquidityDriver internal lp;

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        pvp = new PVP(); // this test contract stands in for the launch factory
        subsidy = new WorkerSubsidy(owner, updater);
        king = new KingOfThePad(payable(address(subsidy)), INITIAL_CLAIM_PRICE, BUMP_BPS);
        router = new PvPadFeeRouter(pvp, king);
        pad = new PvPad(manager, pvp, router, FEE_BPS);
        hook = deployHook(manager);
        pad.initialize(hook, SQRT_PRICE_1_1);

        lp = new LiquidityDriver(manager);
        vm.deal(address(this), 1_000 ether);
        pvp.approve(address(lp), type(uint256).max);
        lp.modify{value: 100 ether}(pad.poolKey(), SEED_LIQUIDITY);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    uint256 private nextSalt;

    /// @dev Mines a CREATE2 salt from this contract so the hook lands on an address carrying exactly
    /// the two declared bits, the same way the deployer will. Salts are never reused within a test.
    function deployHook(IPoolManager m) internal returns (PvPadHook) {
        bytes memory creationCode = abi.encodePacked(type(PvPadHook).creationCode, abi.encode(address(m)));
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = nextSalt; i < nextSalt + 500_000; i++) {
            address predicted = address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash))
                    )
                )
            );
            if (!HookFlags.matches(predicted, HOOK_FLAGS)) continue;
            PvPadHook deployed = new PvPadHook{salt: bytes32(i)}(m);
            assertEq(address(deployed), predicted, "create2 prediction");
            nextSalt = i + 1;
            return deployed;
        }
        revert("no salt found");
    }

    function key() internal view returns (PoolKey memory) {
        return pad.poolKey();
    }

    function sqrtPrice() internal view returns (uint160 p) {
        (p,,,) = IPoolManager(address(manager)).getSlot0(key().toId());
    }

    function assertManagerSettled() internal view {
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0, "nonzero deltas");
        assertEq(IPoolManager(address(manager)).isUnlocked(), false, "manager still unlocked");
        assertEq(address(pad).balance, 0, "pad holds ETH");
        assertEq(pvp.balanceOf(address(pad)), 0, "pad holds PVP");
    }

    function assertRouterConserved() internal view {
        assertEq(address(router).balance, router.totalPending() + router.unassigned(), "router conservation");
    }

    receive() external payable {}
}
