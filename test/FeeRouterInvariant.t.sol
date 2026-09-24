// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./utils/Fixture.sol";
import {PvPad} from "../src/PvPad.sol";
import {PvPadFeeRouter} from "../src/PvPadFeeRouter.sol";
import {PvPadBurner} from "../src/PvPadBurner.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {GreedyBeneficiary, RejectingReceiver} from "./mocks/Actors.sol";

/// @dev Drives the router through deposits, king changes, deliveries and withdrawals with a mix of
/// EOA, compliant, greedy and rejecting beneficiaries, never reverting.
contract RouterHandler is Test {
    PvPad public pad;
    PvPadFeeRouter public router;
    KingOfThePad public king;
    address[] public beneficiaries;

    constructor(PvPad p, PvPadFeeRouter r, KingOfThePad k, address[] memory b) {
        pad = p;
        router = r;
        king = k;
        beneficiaries = b;
    }

    function _pick(uint256 seed) internal view returns (address) {
        return beneficiaries[seed % beneficiaries.length];
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 5 ether);
        vm.deal(address(this), amount);
        router.depositFees{value: amount}();
    }

    function trade(uint256 amount) external {
        amount = bound(amount, 1e12, 2 ether);
        vm.deal(address(this), amount);
        // The pool can run out of range after many one-way buys; that revert is the pad's, not the router's.
        try pad.buy{value: amount}(0, block.timestamp, address(this)) {} catch {}
    }

    function crown(uint256 seed) external {
        uint256 price = king.claimPrice() + 1;
        if (price > 100 ether) return;
        vm.deal(address(this), price);
        king.claim{value: price}(_pick(seed));
    }

    function assign() external {
        router.assignUnassigned();
    }

    function distribute(uint256 seed, uint256 gas) external {
        router.distribute(_pick(seed), bound(gas, 20_000, 2_000_000));
    }

    function withdraw(uint256 seed) external {
        address who = _pick(seed);
        if (router.pending(who) == 0 || who.code.length != 0) return;
        vm.prank(who);
        router.withdraw(payable(who));
    }

    function sumPending() external view returns (uint256 total) {
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            total += router.pending(beneficiaries[i]);
        }
    }

    receive() external payable {}
}

contract FeeRouterInvariantTest is Fixture {
    RouterHandler handler;
    PvPadBurner burner;

    function setUp() public override {
        super.setUp();
        vm.deal(address(this), 10_000 ether);
        lp.modify{value: 5_000 ether}(key(), 100_000 ether);
        burner = new PvPadBurner(pad, owner);
        vm.prank(owner);
        burner.setQuote(1, type(uint256).max);
        address[] memory b = new address[](5);
        b[0] = alice;
        b[1] = bob;
        b[2] = address(burner);
        b[3] = address(new GreedyBeneficiary());
        b[4] = address(new RejectingReceiver());
        handler = new RouterHandler(pad, router, king, b);
        targetContract(address(handler));
    }

    function invariant_routerBalanceEqualsCredits() public view {
        assertEq(address(router).balance, router.totalPending() + router.unassigned());
        assertEq(
            handler.sumPending(), router.totalPending(), "every pending wei belongs to a known beneficiary"
        );
    }

    function invariant_padAndHookHoldNothing() public view {
        assertEq(address(pad).balance, 0);
        assertEq(pvp.balanceOf(address(pad)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(address(king).balance, 0, "king forwards everything");
    }
}
