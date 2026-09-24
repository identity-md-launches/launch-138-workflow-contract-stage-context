// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Fixture} from "./utils/Fixture.sol";
import {PvPad} from "../src/PvPad.sol";
import {PvPadHook} from "../src/PvPadHook.sol";
import {PvPadFeeRouter} from "../src/PvPadFeeRouter.sol";
import {PVP} from "../src/PVP.sol";
import {FakePad, NotAHook, RejectingReceiver, ReenteringSeller} from "./mocks/Actors.sol";

contract PvPadTest is Fixture {
    function test_configuration() public view {
        assertEq(address(pad.poolManager()), address(manager));
        assertEq(address(pad.token()), address(pvp));
        assertEq(address(pad.feeRouter()), address(router));
        assertEq(pad.configurator(), address(this));
        assertEq(pad.feeBps(), 100);
        assertEq(pad.feeOn(1 ether), 0.01 ether);
        assertEq(pad.feeOn(99), 0, "rounds down");
        assertEq(sqrtPrice(), SQRT_PRICE_1_1);
    }

    function test_constructorValidation() public {
        vm.expectRevert(PvPad.InvalidConfiguration.selector);
        new PvPad(IPoolManager(address(0xBEEF)), IERC20(address(pvp)), router, 100);
        vm.expectRevert(PvPad.InvalidConfiguration.selector);
        new PvPad(manager, IERC20(address(0xBEEF)), router, 100);
        vm.expectRevert(PvPad.InvalidConfiguration.selector);
        new PvPad(manager, IERC20(address(pvp)), PvPadFeeRouter(payable(address(0xBEEF))), 100);
        vm.expectRevert(PvPad.InvalidConfiguration.selector);
        new PvPad(manager, IERC20(address(pvp)), router, 1001);
        // A router built for a different token is refused.
        PVP other = new PVP();
        PvPadFeeRouter otherRouter = new PvPadFeeRouter(other, king);
        vm.expectRevert(PvPad.InvalidConfiguration.selector);
        new PvPad(manager, IERC20(address(pvp)), otherRouter, 100);
        // Zero fee and the maximum fee are both allowed.
        new PvPad(manager, IERC20(address(pvp)), router, 0);
        new PvPad(manager, IERC20(address(pvp)), router, 1000);
    }

    // ---- initialize ----

    function test_initializeOnlyOnce() public {
        PvPadHook fresh = deployHook(manager);
        vm.expectRevert(PvPad.Unauthorized.selector);
        pad.initialize(fresh, SQRT_PRICE_1_1);
    }

    function test_initializeOnlyByConfigurator() public {
        PvPad fresh = new PvPad(manager, IERC20(address(pvp)), router, 100);
        PvPadHook freshHook = deployHook(manager);
        vm.prank(alice);
        vm.expectRevert(PvPad.Unauthorized.selector);
        fresh.initialize(freshHook, SQRT_PRICE_1_1);
    }

    function test_initializeRejectsHookWithoutTheDeclaredFlags() public {
        PvPad fresh = new PvPad(manager, IERC20(address(pvp)), router, 100);
        NotAHook wrong = new NotAHook(manager);
        vm.expectRevert(PvPad.InvalidConfiguration.selector);
        fresh.initialize(PvPadHook(address(wrong)), SQRT_PRICE_1_1);
        vm.expectRevert(PvPad.InvalidConfiguration.selector);
        fresh.initialize(PvPadHook(address(0xBEEF)), SQRT_PRICE_1_1);
    }

    function test_initializeRejectsHookBuiltForAnotherManager() public {
        PvPad fresh = new PvPad(manager, IERC20(address(pvp)), router, 100);
        PvPadHook foreign = deployHook(IPoolManager(address(0x4444)));
        vm.expectRevert(PvPad.InvalidConfiguration.selector);
        fresh.initialize(foreign, SQRT_PRICE_1_1);
    }

    function test_initializeRevertsAtomicallyWhenHookIsAlreadyBound() public {
        PvPad fresh = new PvPad(manager, IERC20(address(pvp)), router, 100);
        PvPadHook freshHook = deployHook(manager);
        // Someone front-runs the binding with their own pad.
        FakePad fake = new FakePad(manager, address(pvp));
        fake.setHook(address(freshHook));
        fake.bind(freshHook, address(pvp));
        vm.expectRevert(PvPadHook.AlreadyBound.selector);
        fresh.initialize(freshHook, SQRT_PRICE_1_1);
        assertEq(address(fresh.hook()), address(0), "nothing recorded");
        // The market can still open with a new hook.
        PvPadHook another = deployHook(manager);
        fresh.initialize(another, SQRT_PRICE_1_1);
        assertEq(another.pad(), address(fresh));
    }

    function test_initializeRevertsOnInvalidPrice() public {
        PvPad fresh = new PvPad(manager, IERC20(address(pvp)), router, 100);
        PvPadHook freshHook = deployHook(manager);
        vm.expectRevert();
        fresh.initialize(freshHook, 0);
        assertEq(address(fresh.hook()), address(0));
        assertEq(freshHook.pad(), address(0), "bind rolled back with the price failure");
    }

    function test_initializeEmitsAndOpensPool() public {
        PvPad fresh = new PvPad(manager, IERC20(address(pvp)), router, 100);
        PvPadHook freshHook = deployHook(manager);
        vm.expectEmit(true, false, false, true, address(fresh));
        emit PvPad.MarketInitialized(address(freshHook), SQRT_PRICE_1_1);
        fresh.initialize(freshHook, SQRT_PRICE_1_1);
        assertEq(address(fresh.hook()), address(freshHook));
        assertEq(freshHook.pad(), address(fresh));
        assertEq(freshHook.token(), address(pvp));
    }

    // ---- buy ----

    function test_buyTakesFeeAndDeliversPvp() public {
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        uint256 out = pad.buy{value: 1 ether}(0, block.timestamp, alice);
        assertGt(out, 0.98 ether, "1:1 pool, 1% pad fee, small impact");
        assertLt(out, 0.99 ether, "the pad fee comes off the top");
        assertEq(pvp.balanceOf(alice), out);
        assertEq(alice.balance, ethBefore - 1 ether);
        assertEq(router.unassigned(), 0.01 ether, "no king yet, so the fee is unassigned");
        assertEq(address(router).balance, 0.01 ether);
        assertManagerSettled();
        assertRouterConserved();
    }

    function test_buyDeliversToRecipient() public {
        vm.prank(alice);
        uint256 out = pad.buy{value: 1 ether}(0, block.timestamp, bob);
        assertEq(pvp.balanceOf(bob), out);
        assertEq(pvp.balanceOf(alice), 0);
    }

    function test_buyEmitsTrade() public {
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = pad.buy{value: 2 ether}(0, block.timestamp, alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(pad) && logs[i].topics[0] == PvPad.Trade.selector) {
                (bool buy, uint256 input, uint256 output, uint256 fee) =
                    abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
                assertTrue(buy);
                assertEq(input, 2 ether);
                assertEq(output, out);
                assertEq(fee, 0.02 ether);
                found = true;
            }
        }
        assertTrue(found, "Trade event");
    }

    function test_buyRevertsOnSlippage() public {
        vm.prank(alice);
        vm.expectRevert(PvPad.Slippage.selector);
        pad.buy{value: 1 ether}(1 ether, block.timestamp, alice);
        assertManagerSettled();
        assertEq(address(router).balance, 0);
    }

    function test_buyRevertsOnDeadline() public {
        vm.prank(alice);
        vm.expectRevert(PvPad.InvalidTrade.selector);
        pad.buy{value: 1 ether}(0, block.timestamp - 1, alice);
    }

    function test_buyRevertsOnBadArguments() public {
        vm.startPrank(alice);
        vm.expectRevert(PvPad.InvalidTrade.selector);
        pad.buy{value: 0}(0, block.timestamp, alice);
        vm.expectRevert(PvPad.InvalidTrade.selector);
        pad.buy{value: 1 ether}(0, block.timestamp, address(0));
        vm.expectRevert(PvPad.InvalidTrade.selector);
        pad.buy{value: 1 ether}(0, block.timestamp, address(pad));
        vm.stopPrank();
    }

    function test_buyRevertsBeforeInitialize() public {
        PvPad fresh = new PvPad(manager, IERC20(address(pvp)), router, 100);
        vm.prank(alice);
        vm.expectRevert(PvPad.InvalidTrade.selector);
        fresh.buy{value: 1 ether}(0, block.timestamp, alice);
    }

    function test_buyRevertsWhenLiquidityCannotFill() public {
        vm.deal(alice, 1_000_000 ether);
        vm.prank(alice);
        vm.expectRevert(PvPad.PartialFill.selector);
        pad.buy{value: 100_000 ether}(0, block.timestamp, alice);
        assertManagerSettled();
    }

    function test_zeroFeePadRoutesNothing() public {
        PvPad free = new PvPad(manager, IERC20(address(pvp)), router, 0);
        PvPadHook freeHook = deployHook(manager);
        free.initialize(freeHook, SQRT_PRICE_1_1);
        pvp.approve(address(lp), type(uint256).max);
        lp.modify{value: 10 ether}(free.poolKey(), 100 ether);
        vm.prank(alice);
        free.buy{value: 1 ether}(0, block.timestamp, alice);
        assertEq(address(router).balance, 0);
    }

    // ---- sell ----

    function _buyFor(address who, uint256 eth) internal returns (uint256 out) {
        vm.prank(who);
        out = pad.buy{value: eth}(0, block.timestamp, who);
    }

    function test_sellTakesFeeFromOutput() public {
        uint256 got = _buyFor(alice, 1 ether);
        uint256 routerBefore = address(router).balance;
        uint256 ethBefore = alice.balance;
        vm.startPrank(alice);
        pvp.approve(address(pad), got);
        uint256 out = pad.sell(got, 0, block.timestamp, payable(alice));
        vm.stopPrank();
        assertEq(pvp.balanceOf(alice), 0);
        assertEq(alice.balance, ethBefore + out);
        uint256 fee = address(router).balance - routerBefore;
        assertGt(fee, 0);
        assertEq(fee, (out + fee) * 100 / 10_000, "1% of the gross ETH");
        assertGt(out, 0.96 ether);
        assertLt(out, 0.99 ether);
        assertManagerSettled();
        assertRouterConserved();
    }

    function test_sellRequiresAllowance() public {
        uint256 got = _buyFor(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        pad.sell(got, 0, block.timestamp, payable(alice));
        assertManagerSettled();
    }

    function test_sellRevertsOnSlippage() public {
        uint256 got = _buyFor(alice, 1 ether);
        vm.startPrank(alice);
        pvp.approve(address(pad), got);
        vm.expectRevert(PvPad.Slippage.selector);
        pad.sell(got, 1 ether, block.timestamp, payable(alice));
        vm.stopPrank();
        assertEq(pvp.balanceOf(alice), got, "nothing moved");
        assertManagerSettled();
    }

    function test_sellRevertsWhenRecipientRejectsEth() public {
        uint256 got = _buyFor(alice, 1 ether);
        RejectingReceiver rejecting = new RejectingReceiver();
        vm.startPrank(alice);
        pvp.approve(address(pad), got);
        vm.expectRevert(PvPad.PaymentFailed.selector);
        pad.sell(got, 0, block.timestamp, payable(address(rejecting)));
        vm.stopPrank();
        assertEq(pvp.balanceOf(alice), got);
        assertManagerSettled();
    }

    function test_sellRevertsWhenLiquidityCannotFill() public {
        pvp.approve(address(pad), type(uint256).max);
        vm.expectRevert(PvPad.PartialFill.selector);
        pad.sell(1e24, 0, block.timestamp, payable(address(this)));
        assertManagerSettled();
    }

    function test_sellRevertsOnBadArguments() public {
        vm.startPrank(alice);
        vm.expectRevert(PvPad.InvalidTrade.selector);
        pad.sell(0, 0, block.timestamp, payable(alice));
        vm.expectRevert(PvPad.InvalidTrade.selector);
        pad.sell(1, 0, block.timestamp - 1, payable(alice));
        vm.expectRevert(PvPad.InvalidTrade.selector);
        pad.sell(uint256(uint128(type(int128).max)) + 1, 0, block.timestamp, payable(alice));
        vm.stopPrank();
    }

    function test_sellRecipientCannotReenter() public {
        uint256 got = _buyFor(alice, 1 ether);
        ReenteringSeller attacker = new ReenteringSeller(pad);
        vm.startPrank(alice);
        pvp.approve(address(pad), got);
        vm.expectRevert(PvPad.PaymentFailed.selector);
        pad.sell(got, 0, block.timestamp, payable(address(attacker)));
        vm.stopPrank();
        assertFalse(attacker.reentered());
        assertManagerSettled();
    }

    // ---- callback and receive hardening ----

    function test_unlockCallbackRefusesOutsiders() public {
        vm.expectRevert(PvPad.Unauthorized.selector);
        pad.unlockCallback(abi.encode(true, uint256(1), alice));
        // Even the manager, when no pad-initiated swap is in flight.
        vm.prank(address(manager));
        vm.expectRevert(PvPad.Unauthorized.selector);
        pad.unlockCallback(abi.encode(true, uint256(1), alice));
    }

    function test_receiveRefusesPlainEth() public {
        vm.prank(alice);
        (bool ok,) = address(pad).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(pad).balance, 0);
    }

    // ---- fuzz ----

    function testFuzz_buyConservesFunds(uint96 amount) public {
        amount = uint96(bound(amount, 1e6, 20 ether));
        uint256 managerEth = address(manager).balance;
        uint256 managerPvp = pvp.balanceOf(address(manager));
        vm.prank(alice);
        uint256 out = pad.buy{value: amount}(0, block.timestamp, alice);
        uint256 fee = uint256(amount) * 100 / 10_000;
        assertEq(address(manager).balance, managerEth + amount - fee, "pool got the net input");
        assertEq(pvp.balanceOf(address(manager)), managerPvp - out, "pool paid the output");
        assertEq(address(router).balance, fee);
        assertManagerSettled();
        assertRouterConserved();
    }

    function testFuzz_roundTripNeverProfits(uint96 amount) public {
        amount = uint96(bound(amount, 1e9, 20 ether));
        uint256 start = alice.balance;
        vm.startPrank(alice);
        uint256 got = pad.buy{value: amount}(0, block.timestamp, alice);
        pvp.approve(address(pad), got);
        pad.sell(got, 0, block.timestamp, payable(alice));
        vm.stopPrank();
        assertLt(alice.balance, start, "fees and impact are never negative");
        assertManagerSettled();
        assertRouterConserved();
    }
}
