// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {RejectingReceiver} from "./mocks/Actors.sol";

contract KingOfThePadTest is Fixture {
    function test_configuration() public view {
        assertEq(king.workerSubsidy(), address(subsidy));
        assertEq(king.claimPrice(), INITIAL_CLAIM_PRICE);
        assertEq(king.bumpBps(), 1000);
        assertEq(king.king(), address(0));
        assertEq(king.beneficiary(), address(0));
        assertEq(king.claimCount(), 0);
    }

    function test_constructorValidation() public {
        vm.expectRevert(KingOfThePad.InvalidConfiguration.selector);
        new KingOfThePad(payable(address(0xBEEF)), 1, 1000);
        vm.expectRevert(KingOfThePad.InvalidConfiguration.selector);
        new KingOfThePad(payable(address(subsidy)), 0, 1000);
        vm.expectRevert(KingOfThePad.InvalidConfiguration.selector);
        new KingOfThePad(payable(address(subsidy)), 1, 10_001);
        new KingOfThePad(payable(address(subsidy)), 1, 0);
        new KingOfThePad(payable(address(subsidy)), 1, 10_000);
    }

    function test_claimSendsEverythingToWorkers() public {
        uint256 subsidyBefore = address(subsidy).balance;
        vm.expectEmit(true, true, true, true, address(king));
        emit KingOfThePad.KingClaimed(alice, bob, 0.02 ether, 0.022 ether, 1);
        vm.prank(alice);
        king.claim{value: 0.02 ether}(bob);
        assertEq(king.king(), alice);
        assertEq(king.beneficiary(), bob);
        assertEq(king.claimPrice(), 0.022 ether, "winning bid plus 10%");
        assertEq(king.claimCount(), 1);
        assertEq(address(subsidy).balance, subsidyBefore + 0.02 ether, "100% to WorkerSubsidy");
        assertEq(address(king).balance, 0);
    }

    function test_claimMustExceedPrice() public {
        vm.prank(alice);
        vm.expectRevert(KingOfThePad.InvalidBid.selector);
        king.claim{value: INITIAL_CLAIM_PRICE}(bob);
        vm.prank(alice);
        vm.expectRevert(KingOfThePad.InvalidBid.selector);
        king.claim{value: 0}(bob);
        vm.prank(alice);
        king.claim{value: INITIAL_CLAIM_PRICE + 1}(bob);
        assertEq(king.king(), alice);
    }

    function test_claimRejectsZeroBeneficiary() public {
        vm.prank(alice);
        vm.expectRevert(KingOfThePad.InvalidBid.selector);
        king.claim{value: 1 ether}(address(0));
    }

    function test_previousKingIsNeverPaid() public {
        vm.prank(alice);
        king.claim{value: 0.02 ether}(alice);
        uint256 aliceBefore = alice.balance;
        uint256 subsidyBefore = address(subsidy).balance;
        vm.prank(bob);
        king.claim{value: 1 ether}(carol);
        assertEq(alice.balance, aliceBefore, "dethroned king got nothing");
        assertEq(address(subsidy).balance, subsidyBefore + 1 ether);
        assertEq(king.king(), bob);
        assertEq(king.beneficiary(), carol);
        assertEq(king.claimPrice(), 1.1 ether);
    }

    function test_kingCanReclaimWithNewBeneficiary() public {
        vm.startPrank(alice);
        king.claim{value: 0.02 ether}(alice);
        king.claim{value: 0.03 ether}(bob);
        vm.stopPrank();
        assertEq(king.king(), alice);
        assertEq(king.beneficiary(), bob);
        assertEq(king.claimCount(), 2);
    }

    function test_beneficiaryMayBeAContract() public {
        vm.prank(alice);
        king.claim{value: 0.02 ether}(address(lp));
        assertEq(king.beneficiary(), address(lp));
    }

    function test_bumpRoundsUp() public {
        vm.prank(alice);
        king.claim{value: INITIAL_CLAIM_PRICE + 1}(bob); // 10^16 + 1 wei
        // ceil((10^16 + 1) * 0.1) = 10^15 + 1
        assertEq(king.claimPrice(), INITIAL_CLAIM_PRICE + 1 + 1e15 + 1);
    }

    function test_claimRevertsWhenWorkersCannotBeFunded() public {
        RejectingReceiver broken = new RejectingReceiver();
        KingOfThePad k = new KingOfThePad(payable(address(broken)), INITIAL_CLAIM_PRICE, 1000);
        vm.prank(alice);
        vm.expectRevert(KingOfThePad.FundingFailed.selector);
        k.claim{value: 1 ether}(bob);
        assertEq(k.king(), address(0));
        assertEq(k.claimPrice(), INITIAL_CLAIM_PRICE);
        assertEq(k.claimCount(), 0);
    }

    function test_noAdminSurface() public {
        string[6] memory signatures = [
            "setClaimPrice(uint256)",
            "setBeneficiary(address)",
            "withdraw()",
            "transferOwnership(address)",
            "pause()",
            "setBumpBps(uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(king).call(abi.encodeWithSignature(signatures[i], alice, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
    }

    function testFuzz_priceLadder(uint96 first, uint96 second) public {
        first = uint96(bound(first, INITIAL_CLAIM_PRICE + 1, 50 ether));
        vm.prank(alice);
        king.claim{value: first}(alice);
        uint256 expected = uint256(first) + (uint256(first) * 1000 + 9_999) / 10_000;
        assertEq(king.claimPrice(), expected);
        second = uint96(bound(second, 0, 100 ether));
        vm.prank(bob);
        if (second <= expected) {
            vm.expectRevert(KingOfThePad.InvalidBid.selector);
            king.claim{value: second}(bob);
            assertEq(king.king(), alice);
        } else {
            king.claim{value: second}(bob);
            assertEq(king.king(), bob);
            assertEq(address(subsidy).balance, uint256(first) + second);
        }
    }
}
