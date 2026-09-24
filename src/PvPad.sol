// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PvPadHook} from "./PvPadHook.sol";
import {PvPadFeeRouter} from "./PvPadFeeRouter.sol";
import {HookFlags} from "./HookFlags.sol";

/// @title PvPad
/// @notice The immutable native-ETH/PVP market: the only router the canonical pool accepts.
/// Charges a fixed pad fee (`feeBps`, approved default 100 = 1%) on ETH in (buys) or ETH out
/// (sells) and forwards it to PvPadFeeRouter. Holds no liquidity and no user funds between calls.
/// @dev `initialize` is the one-shot that binds the hook to this pad and opens the pool. After it
/// there is no admin, fee setter, pause or upgrade path.
contract PvPad is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IERC20 public immutable token;
    PvPadFeeRouter public immutable feeRouter;
    /// @notice The deployer; the only address that may call `initialize`, once.
    address public immutable configurator;
    /// @notice Pad fee in basis points of ETH. Fixed at deployment.
    uint256 public immutable feeBps;
    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant BPS = 10_000;
    /// @notice The bound hook. Zero until `initialize`.
    PvPadHook public hook;
    bool private swapping;

    error InvalidConfiguration();
    error Unauthorized();
    error InvalidTrade();
    error PartialFill();
    error Slippage();
    error PaymentFailed();

    event MarketInitialized(address indexed hook, uint160 sqrtPriceX96);
    event Trade(
        address indexed trader,
        address indexed recipient,
        bool buy,
        uint256 input,
        uint256 output,
        uint256 fee
    );

    /// @param manager The Uniswap v4 PoolManager (must have code).
    /// @param pvp The PVP token (must have code and match the router's token).
    /// @param router The fee router (must have code).
    /// @param padFeeBps Pad fee in bps, at most 1000. The approved default is 100.
    constructor(IPoolManager manager, IERC20 pvp, PvPadFeeRouter router, uint256 padFeeBps) {
        if (
            address(manager).code.length == 0 || address(pvp).code.length == 0
                || address(router).code.length == 0 || address(router.token()) != address(pvp)
                || padFeeBps > MAX_FEE_BPS
        ) revert InvalidConfiguration();
        poolManager = manager;
        token = pvp;
        feeRouter = router;
        feeBps = padFeeBps;
        configurator = msg.sender;
    }

    /// @notice One-time wiring: record the hook, bind it to this pad and PVP, and open the pool.
    /// @dev `newHook` must be unbound, built for the same PoolManager and sit at an address carrying
    /// exactly the beforeInitialize|beforeSwap bits. The three steps are atomic: if the hook was
    /// already bound elsewhere (see docs/review-notes.md) or the price is invalid, nothing changes.
    function initialize(PvPadHook newHook, uint160 sqrtPriceX96) external nonReentrant {
        if (msg.sender != configurator || address(hook) != address(0)) revert Unauthorized();
        if (
            address(newHook).code.length == 0 || address(newHook.poolManager()) != address(poolManager)
                || !HookFlags.matches(address(newHook), HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP)
        ) revert InvalidConfiguration();
        hook = newHook;
        newHook.bind(address(this), address(token));
        poolManager.initialize(poolKey(), sqrtPriceX96);
        emit MarketInitialized(address(newHook), sqrtPriceX96);
    }

    /// @notice The canonical pool key: native ETH / PVP, 0.30% LP fee, spacing 60, this pad's hook.
    function poolKey() public view returns (PoolKey memory) {
        return
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
    }

    /// @notice Pad fee taken from `ethAmount`, rounded down.
    function feeOn(uint256 ethAmount) public view returns (uint256) {
        return ethAmount * feeBps / BPS;
    }

    function _validate(uint256 amount, uint256 deadline, address recipient) internal view {
        if (
            address(hook) == address(0) || amount == 0 || amount > uint256(uint128(type(int128).max))
                || deadline < block.timestamp || recipient == address(0) || recipient == address(this)
        ) revert InvalidTrade();
    }

    /// @notice Buy PVP with `msg.value`. The fee is taken from the ETH first; the rest is swapped.
    /// @param minPvpOut Minimum PVP delivered to `recipient`, else revert.
    /// @param deadline Last acceptable block timestamp (inclusive).
    function buy(uint256 minPvpOut, uint256 deadline, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 output)
    {
        _validate(msg.value, deadline, recipient);
        uint256 fee = feeOn(msg.value);
        output = _swap(true, msg.value - fee);
        if (output < minPvpOut || output == 0) revert Slippage();
        if (fee != 0) feeRouter.depositFees{value: fee}();
        token.safeTransfer(recipient, output);
        emit Trade(msg.sender, recipient, true, msg.value, output, fee);
    }

    /// @notice Sell `pvpIn` PVP (needs allowance to the pad). The fee is taken from the ETH out.
    /// @param minEthOut Minimum ETH delivered to `recipient` after the pad fee, else revert.
    function sell(uint256 pvpIn, uint256 minEthOut, uint256 deadline, address payable recipient)
        external
        nonReentrant
        returns (uint256 output)
    {
        _validate(pvpIn, deadline, recipient);
        uint256 gross = _swap(false, pvpIn);
        uint256 fee = feeOn(gross);
        output = gross - fee;
        if (output < minEthOut || output == 0) revert Slippage();
        if (fee != 0) feeRouter.depositFees{value: fee}();
        (bool ok,) = recipient.call{value: output}("");
        if (!ok) revert PaymentFailed();
        emit Trade(msg.sender, recipient, false, pvpIn, output, fee);
    }

    function _swap(bool buying, uint256 input) internal returns (uint256 output) {
        swapping = true;
        output = abi.decode(poolManager.unlock(abi.encode(buying, input, msg.sender)), (uint256));
        swapping = false;
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only the PoolManager, and only inside a pad-initiated swap. Exact-input, unlimited price
    /// limit; a fill that does not consume the whole input reverts.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !swapping) revert Unauthorized();
        (bool buying, uint256 input, address payer) = abi.decode(data, (bool, uint256, address));
        BalanceDelta delta = poolManager.swap(
            poolKey(),
            SwapParams(
                buying, -int256(input), buying ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 inputDelta = buying ? delta.amount0() : delta.amount1();
        int128 outputDelta = buying ? delta.amount1() : delta.amount0();
        if (int256(inputDelta) != -int256(input) || outputDelta <= 0) revert PartialFill();
        uint256 output = uint256(uint128(outputDelta));
        if (buying) {
            poolManager.sync(Currency.wrap(address(0)));
            poolManager.settle{value: input}();
            poolManager.take(Currency.wrap(address(token)), address(this), output);
        } else {
            poolManager.sync(Currency.wrap(address(token)));
            token.safeTransferFrom(payer, address(poolManager), input);
            poolManager.settle();
            poolManager.take(Currency.wrap(address(0)), address(this), output);
        }
        return abi.encode(output);
    }

    /// @dev Only the PoolManager may push ETH here (the `take` of a sell's output).
    receive() external payable {
        if (msg.sender != address(poolManager)) revert Unauthorized();
    }
}
