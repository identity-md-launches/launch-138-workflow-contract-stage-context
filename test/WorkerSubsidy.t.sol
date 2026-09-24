// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Fixture} from "./utils/Fixture.sol";
import {Merkle} from "./utils/Merkle.sol";
import {WorkerSubsidy} from "../src/WorkerSubsidy.sol";
import {RejectingReceiver, ReenteringPayee} from "./mocks/Actors.sol";

contract WorkerSubsidyTest is Fixture {
    address[] payees;
    uint256[] amounts;
    bytes32[] leaves;

    function _fund(uint256 amount) internal {
        vm.prank(alice);
        king.claim{value: amount}(alice);
    }

    function _buildEpoch(uint256 id) internal {
        delete leaves;
        for (uint256 i = 0; i < payees.length; i++) {
            leaves.push(subsidy.leaf(id, payees[i], amounts[i]));
        }
    }

    function _openEpoch(uint256 window) internal returns (uint256 id, bytes32 root) {
        id = subsidy.currentEpoch() + 1;
        _buildEpoch(id);
        root = Merkle.root(leaves);
        vm.prank(updater);
        subsidy.setEpoch(root, window);
    }

    function setUp() public override {
        super.setUp();
        payees = [alice, bob, carol];
        amounts = [0.3 ether, 0.2 ether, 0.1 ether];
    }

    function test_configuration() public view {
        assertEq(subsidy.owner(), owner);
        assertEq(subsidy.updater(), updater);
        assertEq(subsidy.currentEpoch(), 0);
        assertEq(subsidy.MAX_WINDOW(), 30 days);
    }

    function test_constructorRejectsZeroUpdater() public {
        vm.expectRevert(WorkerSubsidy.ZeroAddress.selector);
        new WorkerSubsidy(owner, address(0));
    }

    function test_acceptsFunding() public {
        vm.expectEmit(true, false, false, true, address(subsidy));
        emit WorkerSubsidy.Funded(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(subsidy).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(subsidy).balance, 1 ether);
    }

    // ---- updater / owner ----

    function test_setUpdaterOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        subsidy.setUpdater(alice);
        vm.prank(owner);
        vm.expectRevert(WorkerSubsidy.ZeroAddress.selector);
        subsidy.setUpdater(address(0));
        vm.prank(owner);
        subsidy.setUpdater(alice);
        assertEq(subsidy.updater(), alice);
    }

    function test_ownershipIsTwoStep() public {
        vm.prank(owner);
        subsidy.transferOwnership(alice);
        assertEq(subsidy.owner(), owner);
        vm.prank(alice);
        subsidy.acceptOwnership();
        assertEq(subsidy.owner(), alice);
    }

    function test_ownerHasNoWithdrawal() public {
        _fund(1 ether);
        string[4] memory signatures =
            ["withdraw()", "withdraw(uint256)", "sweep(address)", "rescue(address,uint256)"];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(owner);
            (bool ok,) = address(subsidy).call(abi.encodeWithSignature(signatures[i], owner, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(address(subsidy).balance, 1 ether);
    }

    // ---- setEpoch ----

    function test_setEpochOnlyUpdater() public {
        vm.prank(owner);
        vm.expectRevert(WorkerSubsidy.Unauthorized.selector);
        subsidy.setEpoch(bytes32(uint256(1)), 1 days);
    }

    function test_setEpochValidation() public {
        vm.startPrank(updater);
        vm.expectRevert(WorkerSubsidy.InvalidEpoch.selector);
        subsidy.setEpoch(bytes32(0), 1 days);
        vm.expectRevert(WorkerSubsidy.InvalidEpoch.selector);
        subsidy.setEpoch(bytes32(uint256(1)), 0);
        vm.expectRevert(WorkerSubsidy.InvalidEpoch.selector);
        subsidy.setEpoch(bytes32(uint256(1)), 30 days + 1);
        subsidy.setEpoch(bytes32(uint256(1)), 30 days);
        vm.stopPrank();
    }

    function test_setEpochSnapshotsBudgetAndRefusesEarlyReplacement() public {
        _fund(1 ether);
        (uint256 id,) = _openEpoch(7 days);
        (bytes32 root, uint256 budget, uint256 paid, uint256 endsAt) = subsidy.epochs(id);
        assertEq(id, 1);
        assertTrue(root != bytes32(0));
        assertEq(budget, 1 ether);
        assertEq(paid, 0);
        assertEq(endsAt, block.timestamp + 7 days);
        // Funding after the snapshot is reserved for a later epoch.
        vm.prank(bob);
        king.claim{value: 2 ether}(bob);
        (, budget,,) = subsidy.epochs(id);
        assertEq(budget, 1 ether);
        vm.prank(updater);
        vm.expectRevert(WorkerSubsidy.EpochStillOpen.selector);
        subsidy.setEpoch(bytes32(uint256(2)), 1 days);
        vm.warp(endsAt);
        vm.prank(updater);
        subsidy.setEpoch(bytes32(uint256(2)), 1 days);
        (, budget,,) = subsidy.epochs(2);
        assertEq(budget, 3 ether, "unclaimed ETH rolls into the next epoch");
    }

    // ---- claim ----

    function test_claimPaysPayee() public {
        _fund(1 ether);
        (uint256 id,) = _openEpoch(7 days);
        uint256 before = bob.balance;
        bytes32[] memory proof = Merkle.proof(leaves, 1);
        vm.expectEmit(true, true, false, true, address(subsidy));
        emit WorkerSubsidy.Claimed(id, bob, 0.2 ether);
        vm.prank(carol); // anyone may relay
        subsidy.claim(id, payable(bob), 0.2 ether, proof);
        assertEq(bob.balance, before + 0.2 ether);
        assertTrue(subsidy.claimed(id, bob));
        (,, uint256 paid,) = subsidy.epochs(id);
        assertEq(paid, 0.2 ether);
    }

    function test_allPayeesCanClaim() public {
        _fund(1 ether);
        (uint256 id,) = _openEpoch(7 days);
        for (uint256 i = 0; i < payees.length; i++) {
            uint256 before = payees[i].balance;
            subsidy.claim(id, payable(payees[i]), amounts[i], Merkle.proof(leaves, i));
            assertEq(payees[i].balance, before + amounts[i]);
        }
        assertEq(address(subsidy).balance, 0.4 ether);
    }

    function test_claimTwiceFails() public {
        _fund(1 ether);
        (uint256 id,) = _openEpoch(7 days);
        bytes32[] memory proof = Merkle.proof(leaves, 0);
        subsidy.claim(id, payable(alice), 0.3 ether, proof);
        vm.expectRevert(WorkerSubsidy.InvalidClaim.selector);
        subsidy.claim(id, payable(alice), 0.3 ether, proof);
    }

    function test_claimRejectsWrongAmountPayeeOrProof() public {
        _fund(1 ether);
        (uint256 id,) = _openEpoch(7 days);
        bytes32[] memory proof = Merkle.proof(leaves, 0);
        vm.expectRevert(WorkerSubsidy.InvalidClaim.selector);
        subsidy.claim(id, payable(alice), 0.3 ether + 1, proof);
        vm.expectRevert(WorkerSubsidy.InvalidClaim.selector);
        subsidy.claim(id, payable(bob), 0.3 ether, proof);
        vm.expectRevert(WorkerSubsidy.InvalidClaim.selector);
        subsidy.claim(id, payable(alice), 0.3 ether, Merkle.proof(leaves, 1));
        vm.expectRevert(WorkerSubsidy.InvalidClaim.selector);
        subsidy.claim(id, payable(address(0)), 0.3 ether, proof);
        vm.expectRevert(WorkerSubsidy.InvalidClaim.selector);
        subsidy.claim(id, payable(alice), 0, proof);
    }

    function test_claimRejectsOtherEpochsAndExpiry() public {
        _fund(1 ether);
        (uint256 id,) = _openEpoch(7 days);
        bytes32[] memory proof = Merkle.proof(leaves, 0);
        vm.expectRevert(WorkerSubsidy.InvalidEpoch.selector);
        subsidy.claim(0, payable(alice), 0.3 ether, proof);
        vm.expectRevert(WorkerSubsidy.InvalidEpoch.selector);
        subsidy.claim(id + 1, payable(alice), 0.3 ether, proof);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(WorkerSubsidy.InvalidEpoch.selector);
        subsidy.claim(id, payable(alice), 0.3 ether, proof);
        // Once a new epoch opens, the old one's proofs are dead even if it had budget left.
        vm.prank(updater);
        subsidy.setEpoch(bytes32(uint256(7)), 1 days);
        vm.expectRevert(WorkerSubsidy.InvalidEpoch.selector);
        subsidy.claim(id, payable(alice), 0.3 ether, proof);
    }

    function test_claimIsBoundToChainAndContract() public {
        _fund(1 ether);
        (uint256 id,) = _openEpoch(7 days);
        bytes32[] memory proof = Merkle.proof(leaves, 0);
        vm.chainId(11155111);
        vm.expectRevert(WorkerSubsidy.InvalidClaim.selector);
        subsidy.claim(id, payable(alice), 0.3 ether, proof);
        vm.chainId(31337);
        // The same root on another subsidy contract does not verify either.
        WorkerSubsidy other = new WorkerSubsidy(owner, updater);
        vm.deal(address(other), 1 ether);
        vm.prank(updater);
        other.setEpoch(Merkle.root(leaves), 7 days);
        vm.expectRevert(WorkerSubsidy.InvalidClaim.selector);
        other.claim(1, payable(alice), 0.3 ether, proof);
    }

    function test_claimsCannotExceedBudget() public {
        // A dishonest root promising more than the snapshot: the last claimant is refused.
        _fund(0.5 ether);
        (uint256 id,) = _openEpoch(7 days); // leaves sum to 0.6 ether
        subsidy.claim(id, payable(alice), 0.3 ether, Merkle.proof(leaves, 0));
        subsidy.claim(id, payable(bob), 0.2 ether, Merkle.proof(leaves, 1));
        vm.expectRevert(WorkerSubsidy.InvalidClaim.selector);
        subsidy.claim(id, payable(carol), 0.1 ether, Merkle.proof(leaves, 2));
        assertEq(address(subsidy).balance, 0);
    }

    function test_claimRollsBackWhenPayeeRejects() public {
        RejectingReceiver rejecting = new RejectingReceiver();
        payees = [address(rejecting), bob];
        amounts = [0.3 ether, 0.2 ether];
        _fund(1 ether);
        (uint256 id,) = _openEpoch(7 days);
        vm.expectRevert(WorkerSubsidy.PaymentFailed.selector);
        subsidy.claim(id, payable(address(rejecting)), 0.3 ether, Merkle.proof(leaves, 0));
        assertFalse(subsidy.claimed(id, address(rejecting)));
        (,, uint256 paid,) = subsidy.epochs(id);
        assertEq(paid, 0);
    }

    function test_claimRejectsReentrancy() public {
        ReenteringPayee attacker = new ReenteringPayee(subsidy);
        payees = [address(attacker), bob];
        amounts = [0.3 ether, 0.2 ether];
        _fund(1 ether);
        (uint256 id,) = _openEpoch(7 days);
        bytes32[] memory proof = Merkle.proof(leaves, 0);
        attacker.arm(id, 0.3 ether, proof);
        vm.expectRevert(WorkerSubsidy.PaymentFailed.selector);
        subsidy.claim(id, payable(address(attacker)), 0.3 ether, proof);
        assertEq(address(attacker).balance, 0);
        assertEq(address(subsidy).balance, 1 ether);
    }

    function test_singleLeafTree() public {
        payees = [alice];
        amounts = [1 ether];
        _fund(1 ether);
        (uint256 id,) = _openEpoch(1 days);
        bytes32[] memory proof = Merkle.proof(leaves, 0);
        assertEq(proof.length, 0);
        subsidy.claim(id, payable(alice), 1 ether, proof);
        assertEq(address(subsidy).balance, 0);
    }

    function testFuzz_leafIsDomainSeparated(uint256 id, address payee, uint256 amount) public view {
        bytes32 expected = keccak256(
            bytes.concat(keccak256(abi.encode(block.chainid, address(subsidy), id, payee, amount)))
        );
        assertEq(subsidy.leaf(id, payee, amount), expected);
    }
}
