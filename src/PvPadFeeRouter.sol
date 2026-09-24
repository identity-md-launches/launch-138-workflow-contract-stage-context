// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PVP} from "./PVP.sol";
import {KingOfThePad} from "./KingOfThePad.sol";

/// @notice What a contract beneficiary implements to have its fees converted into burned PVP.
interface IBuyAndBurn {
    /// @dev Receives the credited ETH as `msg.value`. The implementation picks venue, slippage and
    /// deadline; the router only checks that PVP's total supply went down.
    function buyAndBurn(address token) external payable;
}

/// @title PvPadFeeRouter
/// @notice Routes pad trading fees to the current KingOfThePad beneficiary. Zero house cut, no owner.
/// @dev Fees are credited to the beneficiary current at deposit time; delivery is a separate,
/// permissionless call so an untrusted beneficiary can never block trading. An EOA beneficiary is
/// sent ETH. A contract beneficiary is offered `buyAndBurn`; if that fails or burns nothing, the
/// credit is restored and stays pullable through `withdraw`, so the router is never bricked.
contract PvPadFeeRouter is ReentrancyGuard {
    PVP public immutable token;
    KingOfThePad public immutable king;
    /// @notice ETH credited and not yet delivered, per beneficiary.
    mapping(address => uint256) public pending;
    /// @notice Fees received before any king existed.
    uint256 public unassigned;
    /// @notice Sum of all `pending` entries; `unassigned + totalPending == address(this).balance`.
    uint256 public totalPending;

    error InvalidConfiguration();
    error OnlySelf();
    error NoBurn();
    error NothingToWithdraw();
    error PaymentFailed();

    event FeesCredited(address indexed beneficiary, uint256 amount);
    event FeesDelivered(address indexed beneficiary, uint256 amount, bool burned);
    event DeliveryDeferred(address indexed beneficiary, uint256 amount);
    event Withdrawn(address indexed beneficiary, address indexed recipient, uint256 amount);

    constructor(PVP pvp, KingOfThePad kingContract) {
        if (address(pvp).code.length == 0 || address(kingContract).code.length == 0) {
            revert InvalidConfiguration();
        }
        token = pvp;
        king = kingContract;
    }

    receive() external payable {
        _credit();
    }

    /// @notice Pad fees and permissionless donations alike.
    function depositFees() external payable {
        _credit();
    }

    function _credit() internal {
        address beneficiary = king.beneficiary();
        if (beneficiary == address(0)) {
            unassigned += msg.value;
        } else {
            pending[beneficiary] += msg.value;
            totalPending += msg.value;
        }
        emit FeesCredited(beneficiary, msg.value);
    }

    /// @notice Assign fees that arrived before the first king to the beneficiary current now.
    function assignUnassigned() external {
        address beneficiary = king.beneficiary();
        uint256 amount = unassigned;
        if (beneficiary == address(0) || amount == 0) return;
        unassigned = 0;
        pending[beneficiary] += amount;
        totalPending += amount;
        emit FeesCredited(beneficiary, amount);
    }

    /// @notice Deliver a beneficiary's credit. Anyone may call. A failed delivery restores the credit.
    /// @param executionGas Gas forwarded to the beneficiary, chosen by the caller so an expensive or
    /// hostile beneficiary cannot consume the whole transaction.
    function distribute(address beneficiary, uint256 executionGas) external nonReentrant {
        uint256 amount = pending[beneficiary];
        if (amount == 0) return;
        pending[beneficiary] = 0;
        totalPending -= amount;
        bool ok;
        bool isContract = beneficiary.code.length != 0;
        if (isContract) {
            // The purchase and the supply check share one reverting subcall: no burn, no ETH moved.
            (ok,) = address(this).call{gas: executionGas}(
                abi.encodeCall(this.executeBurn, (beneficiary, amount))
            );
        } else {
            ok = _send(beneficiary, amount, executionGas);
        }
        if (ok) {
            emit FeesDelivered(beneficiary, amount, isContract);
        } else {
            pending[beneficiary] += amount;
            totalPending += amount;
            emit DeliveryDeferred(beneficiary, amount);
        }
    }

    /// @dev Self-call only; isolates the beneficiary's buy-and-burn so it can be rolled back as a unit.
    function executeBurn(address beneficiary, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 beforeSupply = token.totalSupply();
        IBuyAndBurn(beneficiary).buyAndBurn{value: amount}(address(token));
        if (token.totalSupply() >= beforeSupply) revert NoBurn();
    }

    /// @notice Pull one's own credit as plain ETH to any recipient. The non-bricking fallback.
    function withdraw(address payable recipient) external nonReentrant {
        uint256 amount = pending[msg.sender];
        if (amount == 0 || recipient == address(0)) revert NothingToWithdraw();
        pending[msg.sender] = 0;
        totalPending -= amount;
        if (!_send(recipient, amount, gasleft())) revert PaymentFailed();
        emit Withdrawn(msg.sender, recipient, amount);
    }

    /// @dev Plain ETH send that ignores return data, so a recipient cannot return-bomb the router.
    function _send(address to, uint256 amount, uint256 gasBudget) internal returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(gasBudget, to, amount, 0, 0, 0, 0)
        }
    }
}
