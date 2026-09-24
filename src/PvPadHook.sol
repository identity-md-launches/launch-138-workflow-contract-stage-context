// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice The subset of the pad the hook reads back while binding.
interface IPvPadBinder {
    function poolManager() external view returns (IPoolManager);
    function token() external view returns (address);
    function hook() external view returns (address);
}

/// @title PvPadHook
/// @notice Gate-only Uniswap v4 hook for the canonical native-ETH/PVP pad pool.
/// @dev The constructor takes ONLY the PoolManager, so the attested creation code contains no sibling
/// address. The pad and the PVP token are wired later by a one-shot `bind`, which the pad calls on
/// itself from `PvPad.initialize` once both addresses exist. After binding nothing can be changed.
///
/// Permissions: `beforeInitialize` and `beforeSwap` only. Both refuse any caller other than the
/// PoolManager, any `sender` other than the bound pad, and any key other than the canonical one.
/// There are no return-delta permissions, no custody, no owner, no pause, no upgrade path, and
/// liquidity add/remove/donate are never intercepted, so LPs can always exit.
contract PvPadHook {
    /// @notice The only trusted caller of the two callbacks.
    IPoolManager public immutable poolManager;
    /// @notice Static LP fee of the canonical pool, in pips (0.30%).
    uint24 public constant POOL_FEE = 3000;
    /// @notice Tick spacing of the canonical pool.
    int24 public constant TICK_SPACING = 60;

    /// @notice The pad that may initialize and swap on the canonical pool. Zero until `bind`.
    address public pad;
    /// @notice The PVP token that must be `currency1` of the canonical pool. Zero until `bind`.
    address public token;

    error ZeroAddress();
    error AlreadyBound();
    error NotBound();
    error BindMismatch();
    error OnlyPoolManager();
    error OnlyPad();
    error InvalidPool();

    event Bound(address indexed pad, address indexed token);

    constructor(IPoolManager manager) {
        if (address(manager) == address(0)) revert ZeroAddress();
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice One-shot wiring of the pad and the PVP token, called by the pad on itself.
    /// @dev `msg.sender` must be `padAddress`, and the pad must already point at this hook and at the
    /// same PoolManager and token. A second call always reverts. See docs/review-notes.md for the
    /// front-running window this leaves open before initialization and how the deployer closes it.
    function bind(address padAddress, address pvp) external {
        if (pad != address(0)) revert AlreadyBound();
        if (padAddress == address(0) || pvp == address(0)) revert ZeroAddress();
        if (msg.sender != padAddress || pvp.code.length == 0) revert BindMismatch();
        IPvPadBinder binder = IPvPadBinder(padAddress);
        if (
            address(binder.poolManager()) != address(poolManager) || binder.token() != pvp
                || binder.hook() != address(this)
        ) revert BindMismatch();
        pad = padAddress;
        token = pvp;
        emit Bound(padAddress, pvp);
    }

    /// @notice Exactly the two permissions the mined address must carry: bits 13 and 7 (0x2080).
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
    }

    /// @notice The only pool key the hook accepts once bound.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(0)), Currency.wrap(token), POOL_FEE, TICK_SPACING, IHooks(address(this))
        );
    }

    function _check(address sender, PoolKey calldata key) internal view {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        address boundPad = pad;
        if (boundPad == address(0)) revert NotBound();
        if (sender != boundPad) revert OnlyPad();
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != token
                || key.fee != POOL_FEE || key.tickSpacing != TICK_SPACING
                || address(key.hooks) != address(this)
        ) revert InvalidPool();
    }

    /// @notice `IHooks.beforeInitialize`: only the bound pad may open the canonical pool.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        _check(sender, key);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice `IHooks.beforeSwap`: only the bound pad may swap; zero delta, no fee override.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _check(sender, key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
