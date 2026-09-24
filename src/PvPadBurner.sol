// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PVP} from "./PVP.sol";
import {PvPad} from "./PvPad.sol";
import {PvPadFeeRouter, IBuyAndBurn} from "./PvPadFeeRouter.sol";

/// @title PvPadBurner
/// @notice Optional contract beneficiary for KingOfThePad: buys PVP through the pad with the fees
/// it is delivered and burns everything it receives. The operator sets a minimum rate and expiry
/// so the router's buy-and-burn cannot execute at a manipulated price; without a valid quote the
/// ETH stays credited in the router and can be pulled with `withdrawCredit`.
contract PvPadBurner is Ownable2Step, IBuyAndBurn {
    PvPad public immutable pad;
    PvPadFeeRouter public immutable feeRouter;
    /// @notice Minimum PVP minor units per 10^18 wei the burner insists on. Zero disables buying.
    uint256 public minTokensPerEth;
    /// @notice Timestamp after which the quote is stale.
    uint256 public validUntil;

    error InvalidConfiguration();
    error Unauthorized();
    error NoValidQuote();

    event QuoteSet(uint256 minTokensPerEth, uint256 validUntil);
    event Burned(uint256 ethSpent, uint256 tokensBurned);

    constructor(PvPad market, address operator) Ownable(operator) {
        if (address(market).code.length == 0) revert InvalidConfiguration();
        pad = market;
        feeRouter = market.feeRouter();
    }

    function setQuote(uint256 minimumTokensPerEth, uint256 expiresAt) external onlyOwner {
        minTokensPerEth = minimumTokensPerEth;
        validUntil = expiresAt;
        emit QuoteSet(minimumTokensPerEth, expiresAt);
    }

    /// @inheritdoc IBuyAndBurn
    function buyAndBurn(address token) external payable {
        if (msg.sender != address(feeRouter) || token != address(pad.token())) revert Unauthorized();
        if (minTokensPerEth == 0 || block.timestamp > validUntil) revert NoValidQuote();
        uint256 minimum = Math.mulDiv(msg.value, minTokensPerEth, 1 ether, Math.Rounding.Ceil);
        uint256 bought = pad.buy{value: msg.value}(minimum, validUntil, address(this));
        PVP(token).burn(bought);
        emit Burned(msg.value, bought);
    }

    /// @notice Pull this burner's router credit as ETH to `recipient` (fallback when no quote is set).
    function withdrawCredit(address payable recipient) external onlyOwner {
        feeRouter.withdraw(recipient);
    }
}
