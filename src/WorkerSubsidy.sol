// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title WorkerSubsidy
/// @notice Holds king-claim ETH and drips it to Identity MD workers in Merkle epochs.
/// @dev The trusted `updater` publishes `setEpoch(root, window)` only after the off-chain Identity MD
/// `oracle.request` (panelSize 70, quorum 67, bool) attested the root. This contract verifies the
/// updater and the proof; it never calls api.imd.fun and cannot verify the oracle itself. There is
/// no withdrawal, sweep or pause for the owner: unclaimed ETH rolls into the next epoch's budget.
contract WorkerSubsidy is Ownable2Step, ReentrancyGuard {
    struct Epoch {
        bytes32 root;
        uint256 budget;
        uint256 paid;
        uint256 endsAt;
    }

    /// @notice Longest claim window an epoch may have.
    uint256 public constant MAX_WINDOW = 30 days;
    /// @notice The only address that may open epochs. Rotated by the two-step owner.
    address public updater;
    /// @notice Id of the latest epoch; zero before the first one.
    uint256 public currentEpoch;
    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => bool)) public claimed;

    error Unauthorized();
    error InvalidEpoch();
    error EpochStillOpen();
    error InvalidClaim();
    error PaymentFailed();
    error ZeroAddress();

    event Funded(address indexed sender, uint256 amount);
    event UpdaterChanged(address indexed updater);
    event EpochOpened(uint256 indexed epoch, bytes32 root, uint256 budget, uint256 endsAt);
    event Claimed(uint256 indexed epoch, address indexed payee, uint256 amount);

    constructor(address initialOwner, address initialUpdater) Ownable(initialOwner) {
        if (initialUpdater == address(0)) revert ZeroAddress();
        updater = initialUpdater;
        emit UpdaterChanged(initialUpdater);
    }

    /// @notice Accepts king claims and any voluntary funding.
    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    function setUpdater(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        updater = next;
        emit UpdaterChanged(next);
    }

    /// @notice Open the next epoch with an attested root. The budget snapshots the whole balance.
    /// @dev Only after the previous epoch's `endsAt` has passed, even if it was fully claimed.
    function setEpoch(bytes32 root, uint256 window) external nonReentrant {
        if (msg.sender != updater) revert Unauthorized();
        if (root == bytes32(0) || window == 0 || window > MAX_WINDOW) revert InvalidEpoch();
        if (block.timestamp < epochs[currentEpoch].endsAt) revert EpochStillOpen();
        uint256 id = ++currentEpoch;
        uint256 budget = address(this).balance;
        uint256 endsAt = block.timestamp + window;
        epochs[id] = Epoch(root, budget, 0, endsAt);
        emit EpochOpened(id, root, budget, endsAt);
    }

    /// @notice StandardMerkleTree-style double-hashed leaf, bound to chain, contract and epoch.
    function leaf(uint256 id, address payee, uint256 amount) public view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(this), id, payee, amount))));
    }

    /// @notice Pay `amount` to `payee` from epoch `id`. Anyone may relay; ETH always goes to the payee.
    function claim(uint256 id, address payable payee, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Epoch storage epoch = epochs[id];
        if (id == 0 || id != currentEpoch || block.timestamp >= epoch.endsAt) revert InvalidEpoch();
        if (
            payee == address(0) || amount == 0 || claimed[id][payee] || amount > epoch.budget - epoch.paid
                || !MerkleProof.verifyCalldata(proof, epoch.root, leaf(id, payee, amount))
        ) revert InvalidClaim();
        claimed[id][payee] = true;
        epoch.paid += amount;
        (bool ok,) = payee.call{value: amount}("");
        if (!ok) revert PaymentFailed();
        emit Claimed(id, payee, amount);
    }
}
