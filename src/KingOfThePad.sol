// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title KingOfThePad
/// @notice Whoever pays strictly more than `claimPrice` becomes king and names the beneficiary that
/// receives the pad's trading fees. Every wei of every claim goes to WorkerSubsidy; the previous
/// king is never paid from the bid. No admin, no refunds, no expiry.
contract KingOfThePad is ReentrancyGuard {
    /// @notice Receives 100% of each claim.
    address payable public immutable workerSubsidy;
    /// @notice Price bump applied to the winning bid to form the next `claimPrice` (1000 = +10%).
    uint256 public immutable bumpBps;
    /// @notice The minimum bid, exclusive: a claim must pay more than this.
    uint256 public claimPrice;
    /// @notice The current king (the claimer). Zero before the first claim.
    address public king;
    /// @notice Where the fee router sends pad fees. An EOA or a contract (LP, burner, ...).
    address public beneficiary;
    /// @notice Number of successful claims.
    uint256 public claimCount;

    uint256 public constant MAX_BUMP_BPS = 10_000;

    error InvalidConfiguration();
    error InvalidBid();
    error FundingFailed();

    event KingClaimed(
        address indexed king,
        address indexed beneficiary,
        uint256 paid,
        uint256 nextPrice,
        uint256 indexed claimId
    );

    /// @param subsidy The WorkerSubsidy contract (must have code).
    /// @param initialPrice The first exclusive minimum bid, in wei. Must be nonzero.
    /// @param bump The bump in bps, at most 10000. The approved default is 1000.
    constructor(address payable subsidy, uint256 initialPrice, uint256 bump) {
        if (subsidy.code.length == 0 || initialPrice == 0 || bump > MAX_BUMP_BPS) {
            revert InvalidConfiguration();
        }
        workerSubsidy = subsidy;
        claimPrice = initialPrice;
        bumpBps = bump;
    }

    /// @notice Become king. `msg.value` must exceed `claimPrice`; all of it funds workers.
    /// @param nextBeneficiary Nonzero address that will receive pad fees while this claim stands.
    /// @dev Next price = paid + ceil(paid * bumpBps / 10000). If WorkerSubsidy rejects the ETH, the
    /// entire claim reverts, so king, beneficiary and price never change without funding.
    function claim(address nextBeneficiary) external payable nonReentrant {
        if (nextBeneficiary == address(0) || msg.value <= claimPrice) revert InvalidBid();
        king = msg.sender;
        beneficiary = nextBeneficiary;
        uint256 nextPrice = msg.value + Math.mulDiv(msg.value, bumpBps, 10_000, Math.Rounding.Ceil);
        claimPrice = nextPrice;
        uint256 id = ++claimCount;
        (bool ok,) = workerSubsidy.call{value: msg.value}("");
        if (!ok) revert FundingFailed();
        emit KingClaimed(msg.sender, nextBeneficiary, msg.value, nextPrice, id);
    }
}
