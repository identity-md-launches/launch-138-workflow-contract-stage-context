// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Opcodes} from "./utils/Opcodes.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PvPadHook} from "../src/PvPadHook.sol";
import {FakePad} from "./mocks/Actors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PvPadHookTest is Fixture {
    using StateLibrary for IPoolManager;

    function test_constructorTakesOnlyThePoolManager() public {
        // The attested creation code is the runtime initcode plus exactly one ABI word.
        bytes memory creationCode =
            abi.encodePacked(type(PvPadHook).creationCode, abi.encode(address(manager)));
        assertEq(creationCode.length, type(PvPadHook).creationCode.length + 32);
        PvPadHook fresh = deployHook(manager);
        assertEq(address(fresh.poolManager()), address(manager));
        assertEq(fresh.pad(), address(0), "unbound at birth");
        assertEq(fresh.token(), address(0), "unbound at birth");
    }

    function test_constructorRejectsZeroManager() public {
        vm.expectRevert(PvPadHook.ZeroAddress.selector);
        new PvPadHook(IPoolManager(address(0)));
    }

    function test_constructorRejectsAddressWithWrongFlags() public {
        // A plain CREATE address almost never carries exactly 0x2080, and the constructor must notice.
        vm.expectRevert();
        new PvPadHook(manager);
    }

    function test_permissionsMatchDeclaredFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), 0x2080);
        assertEq(HookFlags.flagsOf(address(hook)), HOOK_FLAGS);
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        );
    }

    function test_runtimeHasNoEscapeHatch() public view {
        Opcodes.assertNoEscapeHatch(address(hook).code);
    }

    function test_bindingRecordedByInitialize() public view {
        assertEq(hook.pad(), address(pad));
        assertEq(hook.token(), address(pvp));
        assertEq(address(pad.hook()), address(hook));
        PoolKey memory k = hook.poolKey();
        assertEq(Currency.unwrap(k.currency0), address(0));
        assertEq(Currency.unwrap(k.currency1), address(pvp));
        assertEq(k.fee, 3000);
        assertEq(k.tickSpacing, 60);
        assertEq(address(k.hooks), address(hook));
    }

    function test_bindIsOneShot() public {
        FakePad fake = new FakePad(manager, address(pvp));
        fake.setHook(address(hook));
        vm.expectRevert(PvPadHook.AlreadyBound.selector);
        fake.bind(hook, address(pvp));
        assertEq(hook.pad(), address(pad));
    }

    function test_bindRejectsCallerThatIsNotThePad() public {
        PvPadHook fresh = deployHook(manager);
        FakePad fake = new FakePad(manager, address(pvp));
        fake.setHook(address(fresh));
        // Naming someone else as the pad.
        vm.expectRevert(PvPadHook.BindMismatch.selector);
        fake.bindAs(fresh, address(pad), address(pvp));
        // Calling from an EOA.
        vm.prank(alice);
        vm.expectRevert(PvPadHook.BindMismatch.selector);
        fresh.bind(address(pad), address(pvp));
        assertEq(fresh.pad(), address(0));
    }

    function test_bindRejectsZeroAddresses() public {
        PvPadHook fresh = deployHook(manager);
        vm.expectRevert(PvPadHook.ZeroAddress.selector);
        fresh.bind(address(0), address(pvp));
        vm.expectRevert(PvPadHook.ZeroAddress.selector);
        fresh.bind(address(this), address(0));
    }

    function test_bindRejectsPadThatDoesNotPointAtThisHook() public {
        PvPadHook fresh = deployHook(manager);
        FakePad fake = new FakePad(manager, address(pvp));
        fake.setHook(address(hook)); // points at the other hook
        vm.expectRevert(PvPadHook.BindMismatch.selector);
        fake.bind(fresh, address(pvp));
    }

    function test_bindRejectsTokenMismatch() public {
        PvPadHook fresh = deployHook(manager);
        MockERC20 other = new MockERC20("X", "X", 1e18);
        FakePad fake = new FakePad(manager, address(pvp));
        fake.setHook(address(fresh));
        vm.expectRevert(PvPadHook.BindMismatch.selector);
        fake.bind(fresh, address(other));
        // A token without code is refused even if the pad names it.
        FakePad fake2 = new FakePad(manager, address(0xBEEF));
        fake2.setHook(address(fresh));
        vm.expectRevert(PvPadHook.BindMismatch.selector);
        fake2.bind(fresh, address(0xBEEF));
    }

    function test_bindRejectsManagerMismatch() public {
        PvPadHook fresh = deployHook(manager);
        FakePad fake = new FakePad(IPoolManager(address(0x1234)), address(pvp));
        fake.setHook(address(fresh));
        vm.expectRevert(PvPadHook.BindMismatch.selector);
        fake.bind(fresh, address(pvp));
    }

    function test_bindEmitsAndThenLocks() public {
        PvPadHook fresh = deployHook(manager);
        FakePad fake = new FakePad(manager, address(pvp));
        fake.setHook(address(fresh));
        vm.expectEmit(true, true, false, true, address(fresh));
        emit PvPadHook.Bound(address(fake), address(pvp));
        fake.bind(fresh, address(pvp));
        assertEq(fresh.pad(), address(fake));
        assertEq(fresh.token(), address(pvp));
        vm.expectRevert(PvPadHook.AlreadyBound.selector);
        fake.bind(fresh, address(pvp));
    }

    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        PoolKey memory k = key();
        vm.expectRevert(PvPadHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(pad), k, SQRT_PRICE_1_1);
        vm.expectRevert(PvPadHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(pad), k, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
        // Undeclared callbacks are simply not there.
        (bool ok,) = address(hook)
            .call(
                abi.encodeCall(
                    IHooks.beforeAddLiquidity, (address(pad), k, ModifyLiquidityParams(-60, 60, 1, 0), "")
                )
            );
        assertFalse(ok);
    }

    function test_callbacksRefuseSenderOtherThanThePad() public {
        PoolKey memory k = key();
        vm.startPrank(address(manager));
        vm.expectRevert(PvPadHook.OnlyPad.selector);
        hook.beforeInitialize(alice, k, SQRT_PRICE_1_1);
        vm.expectRevert(PvPadHook.OnlyPad.selector);
        hook.beforeSwap(address(lp), k, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
        vm.stopPrank();
    }

    function test_callbacksRefuseWhenUnbound() public {
        PvPadHook fresh = deployHook(manager);
        PoolKey memory k = key();
        k.hooks = IHooks(address(fresh));
        vm.startPrank(address(manager));
        vm.expectRevert(PvPadHook.NotBound.selector);
        fresh.beforeInitialize(address(pad), k, SQRT_PRICE_1_1);
        vm.expectRevert(PvPadHook.NotBound.selector);
        fresh.beforeSwap(address(pad), k, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
        vm.stopPrank();
    }

    function test_callbacksRefuseWrongKey() public {
        PoolKey memory k = key();
        vm.startPrank(address(manager));

        PoolKey memory wrongFee = k;
        wrongFee.fee = 500;
        vm.expectRevert(PvPadHook.InvalidPool.selector);
        hook.beforeInitialize(address(pad), wrongFee, SQRT_PRICE_1_1);

        PoolKey memory wrongSpacing = k;
        wrongSpacing.tickSpacing = 10;
        vm.expectRevert(PvPadHook.InvalidPool.selector);
        hook.beforeSwap(address(pad), wrongSpacing, SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");

        PoolKey memory wrongToken = k;
        wrongToken.currency1 = Currency.wrap(address(0xBEEF));
        vm.expectRevert(PvPadHook.InvalidPool.selector);
        hook.beforeInitialize(address(pad), wrongToken, SQRT_PRICE_1_1);

        PoolKey memory wrongHook = k;
        wrongHook.hooks = IHooks(address(0xBEEF));
        vm.expectRevert(PvPadHook.InvalidPool.selector);
        hook.beforeInitialize(address(pad), wrongHook, SQRT_PRICE_1_1);

        PoolKey memory notNative = k;
        notNative.currency0 = Currency.wrap(address(1));
        vm.expectRevert(PvPadHook.InvalidPool.selector);
        hook.beforeInitialize(address(pad), notNative, SQRT_PRICE_1_1);
        vm.stopPrank();
    }

    function test_callbacksAcceptThePadWithTheCanonicalKey() public {
        vm.startPrank(address(manager));
        assertEq(hook.beforeInitialize(address(pad), key(), SQRT_PRICE_1_1), IHooks.beforeInitialize.selector);
        (bytes4 sel, BeforeSwapDelta delta, uint24 feeOverride) =
            hook.beforeSwap(address(pad), key(), SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "");
        vm.stopPrank();
        assertEq(sel, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
        assertEq(feeOverride, 0);
    }

    function test_outsiderCannotSwapOnTheCanonicalPool() public {
        PoolKey memory k = key();
        vm.expectRevert();
        lp.bypassSwap(k);
    }

    function test_outsiderCannotInitializeAPoolWithThisHook() public {
        PoolKey memory k = key();
        k.fee = 500; // a different pool id, same hook
        vm.expectRevert();
        lp.initialize(k, SQRT_PRICE_1_1);
        k = key();
        k.currency1 = Currency.wrap(address(new MockERC20("X", "X", 1)));
        vm.expectRevert();
        lp.initialize(k, SQRT_PRICE_1_1);
    }

    function test_liquidityCanAlwaysBeAddedAndRemoved() public {
        uint128 before = IPoolManager(address(manager)).getLiquidity(key().toId());
        uint256 ethBefore = address(this).balance;
        uint256 pvpBefore = pvp.balanceOf(address(this));
        lp.modify{value: 10 ether}(key(), 100 ether);
        assertEq(IPoolManager(address(manager)).getLiquidity(key().toId()), before + 100 ether);
        lp.modify(key(), -int256(uint256(before)) - 100 ether);
        assertEq(IPoolManager(address(manager)).getLiquidity(key().toId()), 0, "the LP could exit entirely");
        assertGt(address(this).balance, ethBefore, "ETH came back to the LP");
        assertGt(pvp.balanceOf(address(this)), pvpBefore, "PVP came back to the LP");
        assertManagerSettled();
    }

    function test_hookHoldsNothing() public {
        vm.prank(alice);
        pad.buy{value: 1 ether}(0, block.timestamp, alice);
        assertEq(address(hook).balance, 0);
        assertEq(pvp.balanceOf(address(hook)), 0);
    }
}
