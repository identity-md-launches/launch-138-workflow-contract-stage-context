// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Fixture} from "./utils/Fixture.sol";
import {PVP} from "../src/PVP.sol";
import {PvPad} from "../src/PvPad.sol";
import {PvPadFeeRouter} from "../src/PvPadFeeRouter.sol";
import {PvPadBurner} from "../src/PvPadBurner.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {
    RejectingReceiver,
    GasHog,
    ReturnBomb,
    GreedyBeneficiary,
    RevertingBeneficiary,
    ReenteringBeneficiary,
    KingFlipper
} from "./mocks/Actors.sol";

contract PvPadFeeRouterTest is Fixture {
    address operator = makeAddr("operator");
    PvPadBurner burner;

    function setUp() public override {
        super.setUp();
        burner = new PvPadBurner(pad, operator);
    }

    function _crown(address who, address beneficiary) internal {
        vm.prank(who);
        king.claim{value: king.claimPrice() + 1}(beneficiary);
    }

    function _deposit(address from, uint256 amount) internal {
        vm.prank(from);
        router.depositFees{value: amount}();
    }

    function test_configuration() public view {
        assertEq(address(router.token()), address(pvp));
        assertEq(address(router.king()), address(king));
        assertEq(router.unassigned(), 0);
        assertEq(router.totalPending(), 0);
    }

    function test_constructorValidation() public {
        vm.expectRevert(PvPadFeeRouter.InvalidConfiguration.selector);
        new PvPadFeeRouter(PVP(address(0xBEEF)), king);
        vm.expectRevert(PvPadFeeRouter.InvalidConfiguration.selector);
        new PvPadFeeRouter(pvp, KingOfThePad(address(0xBEEF)));
    }

    // ---- crediting ----

    function test_feesBeforeAnyKingAreUnassigned() public {
        vm.expectEmit(true, false, false, true, address(router));
        emit PvPadFeeRouter.FeesCredited(address(0), 1 ether);
        _deposit(alice, 1 ether);
        assertEq(router.unassigned(), 1 ether);
        assertEq(router.totalPending(), 0, "unassigned fees are not anyone's pending credit yet");
        assertRouterConserved();
        router.assignUnassigned(); // no king yet: a no-op
        assertEq(router.unassigned(), 1 ether);
        _crown(bob, carol);
        router.assignUnassigned();
        assertEq(router.unassigned(), 0);
        assertEq(router.pending(carol), 1 ether);
        assertEq(router.totalPending(), 1 ether);
        assertRouterConserved();
    }

    function test_feesGoToTheBeneficiaryCurrentAtDepositTime() public {
        _crown(alice, bob);
        _deposit(alice, 1 ether);
        _crown(carol, carol);
        _deposit(alice, 2 ether);
        assertEq(router.pending(bob), 1 ether, "earlier fees stay with the earlier beneficiary");
        assertEq(router.pending(carol), 2 ether);
        assertEq(router.totalPending(), 3 ether);
        assertRouterConserved();
    }

    function test_plainTransfersAreCreditedToo() public {
        _crown(alice, bob);
        vm.prank(alice);
        (bool ok,) = address(router).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(router.pending(bob), 0.5 ether);
    }

    function test_padTradesCreditTheBeneficiary() public {
        _crown(alice, bob);
        vm.prank(carol);
        pad.buy{value: 1 ether}(0, block.timestamp, carol);
        assertEq(router.pending(bob), 0.01 ether);
        assertRouterConserved();
    }

    // ---- EOA delivery ----

    function test_distributeSendsEthToEoa() public {
        _crown(alice, bob);
        _deposit(alice, 1 ether);
        uint256 before = bob.balance;
        vm.expectEmit(true, false, false, true, address(router));
        emit PvPadFeeRouter.FeesDelivered(bob, 1 ether, false);
        vm.prank(carol); // anyone may deliver
        router.distribute(bob, 50_000);
        assertEq(bob.balance, before + 1 ether);
        assertEq(router.pending(bob), 0);
        assertEq(router.totalPending(), 0);
        assertRouterConserved();
        router.distribute(bob, 50_000); // nothing left: a no-op
    }

    function test_distributeToRejectingContractIsDeferred() public {
        RejectingReceiver rejecting = new RejectingReceiver();
        _crown(alice, address(rejecting));
        _deposit(alice, 1 ether);
        vm.expectEmit(true, false, false, true, address(router));
        emit PvPadFeeRouter.DeliveryDeferred(address(rejecting), 1 ether);
        router.distribute(address(rejecting), 100_000);
        assertEq(router.pending(address(rejecting)), 1 ether, "credit restored");
        assertRouterConserved();
    }

    function test_distributeIsolatesGasHogs() public {
        GasHog hog = new GasHog();
        _crown(alice, address(hog));
        _deposit(alice, 1 ether);
        router.distribute(address(hog), 100_000);
        assertEq(router.pending(address(hog)), 1 ether);
        assertRouterConserved();
    }

    function test_distributeSurvivesReturnBombs() public {
        ReturnBomb bomb = new ReturnBomb();
        _crown(alice, address(bomb));
        _deposit(alice, 1 ether);
        router.distribute(address(bomb), 200_000);
        assertEq(router.pending(address(bomb)), 1 ether, "a contract beneficiary must burn, not bomb");
        assertRouterConserved();
    }

    // ---- contract delivery (buy-and-burn) ----

    function test_distributeBurnsThroughACompliantBeneficiary() public {
        _crown(alice, address(burner));
        _deposit(alice, 1 ether);
        vm.prank(operator);
        burner.setQuote(0.5e18, block.timestamp + 1 days);
        uint256 supplyBefore = pvp.totalSupply();
        vm.expectEmit(true, false, false, true, address(router));
        emit PvPadFeeRouter.FeesDelivered(address(burner), 1 ether, true);
        router.distribute(address(burner), 1_000_000);
        assertLt(pvp.totalSupply(), supplyBefore, "PVP was burned");
        assertEq(pvp.balanceOf(address(burner)), 0, "everything bought was burned");
        assertEq(
            router.pending(address(burner)),
            0.01 ether,
            "the burner's own buy paid the pad fee back to itself"
        );
        assertEq(address(burner).balance, 0);
        assertRouterConserved();
        assertManagerSettled();
    }

    function test_distributeDefersWhenNothingWasBurned() public {
        GreedyBeneficiary greedy = new GreedyBeneficiary();
        _crown(alice, address(greedy));
        _deposit(alice, 1 ether);
        uint256 supplyBefore = pvp.totalSupply();
        vm.expectEmit(true, false, false, true, address(router));
        emit PvPadFeeRouter.DeliveryDeferred(address(greedy), 1 ether);
        router.distribute(address(greedy), 500_000);
        assertEq(pvp.totalSupply(), supplyBefore);
        assertEq(address(greedy).balance, 0, "the ETH came back with the revert");
        assertEq(router.pending(address(greedy)), 1 ether);
        assertRouterConserved();
    }

    function test_distributeDefersWhenBeneficiaryReverts() public {
        RevertingBeneficiary broken = new RevertingBeneficiary();
        _crown(alice, address(broken));
        _deposit(alice, 1 ether);
        router.distribute(address(broken), 500_000);
        assertEq(router.pending(address(broken)), 1 ether);
        assertRouterConserved();
    }

    function test_distributeDefersWhenGasIsTooLow() public {
        _crown(alice, address(burner));
        _deposit(alice, 1 ether);
        vm.prank(operator);
        burner.setQuote(1, block.timestamp + 1 days);
        router.distribute(address(burner), 30_000);
        assertEq(router.pending(address(burner)), 1 ether);
        assertRouterConserved();
    }

    function test_distributeBlocksReentrancy() public {
        ReenteringBeneficiary attacker = new ReenteringBeneficiary(router);
        _crown(alice, address(attacker));
        _deposit(alice, 1 ether);
        router.distribute(address(attacker), 500_000);
        assertEq(router.pending(address(attacker)), 1 ether, "re-entrant delivery failed and was deferred");
        assertEq(address(attacker).balance, 0);
        assertRouterConserved();
    }

    function test_beneficiaryFlippingTheKingCannotTouchOtherCredits() public {
        KingFlipper flipper = new KingFlipper(king, carol);
        pvp.transfer(address(flipper), 10);
        _crown(alice, bob);
        _deposit(alice, 1 ether);
        _crown(alice, address(flipper));
        _deposit(alice, 1 ether);
        assertEq(router.pending(bob), 1 ether);
        router.distribute(address(flipper), 500_000);
        assertEq(king.beneficiary(), carol, "the flipper used its ETH to crown a new king");
        assertEq(router.pending(address(flipper)), 0);
        assertEq(router.pending(bob), 1 ether, "bob's credit is untouched");
        assertEq(router.pending(carol), 0);
        assertRouterConserved();
    }

    function test_executeBurnIsSelfOnly() public {
        vm.expectRevert(PvPadFeeRouter.OnlySelf.selector);
        router.executeBurn(address(burner), 1);
        vm.prank(operator);
        vm.expectRevert(PvPadFeeRouter.OnlySelf.selector);
        router.executeBurn(address(burner), 1);
    }

    // ---- withdraw ----

    function test_withdrawOnlyByCreditedBeneficiary() public {
        _crown(alice, bob);
        _deposit(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(PvPadFeeRouter.NothingToWithdraw.selector);
        router.withdraw(payable(alice));
        vm.prank(bob);
        vm.expectRevert(PvPadFeeRouter.NothingToWithdraw.selector);
        router.withdraw(payable(address(0)));
        uint256 before = carol.balance;
        vm.expectEmit(true, true, false, true, address(router));
        emit PvPadFeeRouter.Withdrawn(bob, carol, 1 ether);
        vm.prank(bob);
        router.withdraw(payable(carol));
        assertEq(carol.balance, before + 1 ether);
        assertEq(router.pending(bob), 0);
        assertRouterConserved();
    }

    function test_withdrawRevertsWhenRecipientRejects() public {
        RejectingReceiver rejecting = new RejectingReceiver();
        _crown(alice, bob);
        _deposit(alice, 1 ether);
        vm.prank(bob);
        vm.expectRevert(PvPadFeeRouter.PaymentFailed.selector);
        router.withdraw(payable(address(rejecting)));
        assertEq(router.pending(bob), 1 ether);
    }

    function test_noHouseCutAndNoAdmin() public {
        _crown(alice, bob);
        _deposit(alice, 1 ether);
        assertEq(router.pending(bob), 1 ether, "every wei is the beneficiary's");
        string[5] memory signatures = [
            "setTreasury(address)",
            "setHouseCut(uint256)",
            "sweep(address)",
            "pause()",
            "transferOwnership(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(router).call(abi.encodeWithSignature(signatures[i], alice, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
    }

    // ---- burner ----

    function test_burnerConfiguration() public view {
        assertEq(address(burner.pad()), address(pad));
        assertEq(address(burner.feeRouter()), address(router));
        assertEq(burner.owner(), operator);
        assertEq(burner.minTokensPerEth(), 0);
    }

    function test_burnerConstructorRejectsNonPad() public {
        vm.expectRevert(PvPadBurner.InvalidConfiguration.selector);
        new PvPadBurner(PvPad(payable(address(0xBEEF))), operator);
    }

    function test_burnerQuoteOnlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        burner.setQuote(1, block.timestamp);
        vm.prank(operator);
        vm.expectEmit(false, false, false, true, address(burner));
        emit PvPadBurner.QuoteSet(5, 99);
        burner.setQuote(5, 99);
        assertEq(burner.minTokensPerEth(), 5);
        assertEq(burner.validUntil(), 99);
    }

    function test_burnerRefusesCallersOtherThanTheRouter() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(PvPadBurner.Unauthorized.selector);
        burner.buyAndBurn{value: 1 ether}(address(pvp));
        vm.prank(address(router));
        vm.expectRevert(PvPadBurner.Unauthorized.selector);
        burner.buyAndBurn(address(0xBEEF));
    }

    function test_burnerWithoutQuoteLeavesCreditPullable() public {
        _crown(alice, address(burner));
        _deposit(alice, 1 ether);
        router.distribute(address(burner), 1_000_000);
        assertEq(router.pending(address(burner)), 1 ether, "no quote: nothing bought");
        // An expired quote behaves the same.
        vm.prank(operator);
        burner.setQuote(1, block.timestamp - 1);
        router.distribute(address(burner), 1_000_000);
        assertEq(router.pending(address(burner)), 1 ether);
        // The operator can fall back to plain ETH.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        burner.withdrawCredit(payable(alice));
        uint256 before = carol.balance;
        vm.prank(operator);
        burner.withdrawCredit(payable(carol));
        assertEq(carol.balance, before + 1 ether);
        assertEq(router.pending(address(burner)), 0);
        assertRouterConserved();
    }

    function test_burnerRefusesUnfavourableQuote() public {
        _crown(alice, address(burner));
        _deposit(alice, 1 ether);
        vm.prank(operator);
        burner.setQuote(2e18, block.timestamp + 1 days); // the pool is at 1:1
        uint256 supplyBefore = pvp.totalSupply();
        router.distribute(address(burner), 1_000_000);
        assertEq(pvp.totalSupply(), supplyBefore);
        assertEq(router.pending(address(burner)), 1 ether);
        assertRouterConserved();
        assertManagerSettled();
    }

    function test_burnerEmitsBurned() public {
        _crown(alice, address(burner));
        _deposit(alice, 0.1 ether);
        vm.prank(operator);
        burner.setQuote(0.9e18, block.timestamp + 1 days);
        vm.recordLogs();
        router.distribute(address(burner), 1_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(burner) && logs[i].topics[0] == PvPadBurner.Burned.selector) {
                (uint256 spent, uint256 burned) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(spent, 0.1 ether);
                assertGt(burned, 0.09e18);
                found = true;
            }
        }
        assertTrue(found);
    }
}
