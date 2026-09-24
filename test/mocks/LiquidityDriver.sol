// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test-only router. Owns LP positions in the canonical pool (which the hook must allow) and
/// also plays the outsider that tries to swap or initialize around the pad (which it must refuse).
contract LiquidityDriver is IUnlockCallback {
    IPoolManager public immutable manager;

    uint8 constant ACTION_MODIFY = 0;
    uint8 constant ACTION_SWAP = 1;

    constructor(IPoolManager m) {
        manager = m;
    }

    /// @notice Add (positive) or remove (negative) liquidity between ticks -600 and 600, settling with the caller.
    function modify(PoolKey memory key, int256 liquidity) external payable {
        manager.unlock(abi.encode(ACTION_MODIFY, key, liquidity, msg.sender));
        uint256 refund = address(this).balance;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "refund failed");
        }
    }

    /// @notice Attempt a swap as a router that is not the pad.
    function bypassSwap(PoolKey memory key) external {
        manager.unlock(abi.encode(ACTION_SWAP, key, int256(0), msg.sender));
    }

    /// @notice Attempt to initialize a pool as a sender that is not the pad.
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external {
        manager.initialize(key, sqrtPriceX96);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (uint8 action, PoolKey memory key, int256 liquidity, address payer) =
            abi.decode(data, (uint8, PoolKey, int256, address));
        if (action == ACTION_SWAP) {
            manager.swap(key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
            return "";
        }
        (BalanceDelta delta,) =
            manager.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, liquidity, 0), "");
        _settle(key.currency0, delta.amount0(), payer);
        _settle(key.currency1, delta.amount1(), payer);
        return "";
    }

    function _settle(Currency currency, int128 delta, address payer) internal {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                require(IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(uint128(delta)));
        }
    }

    receive() external payable {}
}
