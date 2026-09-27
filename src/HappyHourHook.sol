// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title Happy Hour hook
/// @notice A Uniswap v4 hook for native-ETH pools. Every swap pays a 1% fee on its ETH side, sent to the dead
/// address within the same swap, except during one free hour per UTC day. The free hour starts at UTC hour
/// `(day * 7) % 24` where `day = block.timestamp / 86400`, and lasts exactly 3600 seconds.
///
/// @dev Fee placement, by swap shape (all on the ETH side, `currency0`):
///  - ETH is the *specified* currency (exact-input buy, exact-output sell): `beforeSwap` returns a specified
///    delta of +fee. The pool swaps `amountSpecified - fee` on a buy (the user still pays exactly what they
///    specified, 1% of it is burned) and `amountSpecified + fee` on an exact-output sell (the user still
///    receives exactly what they asked for, the pool gives 1% more, which is burned).
///  - ETH is the *unspecified* currency (exact-output buy, exact-input sell): `afterSwap` reads the pool's ETH
///    amount and returns +fee as the unspecified delta. The user pays 1% more ETH on a buy and receives 1% less
///    on a sell; the pool's own amounts match a hookless pool exactly.
/// In every shape the fee equals 1% (rounded down) of the ETH amount a hookless pool would move for the same
/// swap parameters, and is taken from the PoolManager straight to the dead address. The hook never holds
/// ETH or tokens between calls and has no owner, admin, setter, pause, sweep, or upgrade path.
contract HappyHourHook is IHooks {
    using Hooks for IHooks;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    /// @notice Emitted on every swap that was charged a fee.
    /// @param poolId The pool the swap ran on.
    /// @param amount The ETH amount (wei) sent to the dead address.
    event FeeBurned(PoolId indexed poolId, uint256 amount);

    /// @notice Constructor was given the zero address as PoolManager.
    error ZeroPoolManager();
    /// @notice A callback was called by something other than the PoolManager.
    error NotPoolManager();
    /// @notice A callback the hook does not declare was called.
    error HookNotImplemented();

    /// @notice Where fees go. Nothing can move ETH out of it.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice Fee outside the free hour, in basis points.
    uint256 public constant FEE_BPS = 100;
    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Seconds per UTC day.
    uint256 public constant DAY = 86_400;
    /// @notice Length of the free hour, in seconds.
    uint256 public constant HOUR = 3_600;
    /// @notice The free hour advances by this many UTC hours every day.
    uint256 public constant HOUR_STEP = 7;

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param _poolManager The Uniswap v4 PoolManager. Must be non-zero. The hook must be deployed at an
    /// address carrying exactly the bits in `getHookPermissions()`, or the constructor reverts with
    /// `Hooks.HookAddressNotValid`.
    constructor(IPoolManager _poolManager) {
        if (address(_poolManager) == address(0)) revert ZeroPoolManager();
        poolManager = _poolManager;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    /// @notice The callbacks this hook implements. Must agree with the low 14 bits of its address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------------
    // Schedule views
    // ---------------------------------------------------------------------------------------------

    /// @notice Start of the free hour on UTC day `day` (`day = timestamp / 86400`), as a Unix timestamp.
    function happyHourStart(uint256 day) public pure returns (uint256) {
        return day * DAY + ((day * HOUR_STEP) % 24) * HOUR;
    }

    /// @notice True while the current block is inside today's free hour.
    function isHappyHour() public view returns (bool) {
        uint256 start = happyHourStart(block.timestamp / DAY);
        return block.timestamp >= start && block.timestamp < start + HOUR;
    }

    /// @notice Start of the next free hour that has not begun yet. Today's if it is still ahead, otherwise
    /// tomorrow's (so during a free hour this already points at the following day).
    function nextHappyHour() public view returns (uint256) {
        uint256 day = block.timestamp / DAY;
        uint256 start = happyHourStart(day);
        return block.timestamp < start ? start : happyHourStart(day + 1);
    }

    /// @notice The fee charged on the ETH side of a swap right now: 100 outside the free hour, 0 inside.
    function currentFeeBps() public view returns (uint256) {
        return isHappyHour() ? 0 : FEE_BPS;
    }

    // ---------------------------------------------------------------------------------------------
    // Swap callbacks
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // ETH is the specified currency on an exact-input buy (0 -> 1, amountSpecified < 0) and on an
        // exact-output sell (1 -> 0, amountSpecified > 0). The other two shapes are handled in afterSwap.
        bool exactInput = params.amountSpecified < 0;
        if (!_charges(key) || exactInput != params.zeroForOne) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 ethAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = _fee(ethAmount);
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        _burn(key, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        // ETH is the unspecified currency on an exact-output buy (0 -> 1, amountSpecified > 0) and on an
        // exact-input sell (1 -> 0, amountSpecified < 0). `delta` is the pool's own result, before any hook
        // adjustment, so its ETH leg is exactly what a hookless pool would move.
        bool exactInput = params.amountSpecified < 0;
        if (!_charges(key) || exactInput == params.zeroForOne) {
            return (IHooks.afterSwap.selector, 0);
        }

        int256 amount0 = delta.amount0();
        uint256 ethAmount = amount0 < 0 ? uint256(-amount0) : uint256(amount0);
        uint256 fee = _fee(ethAmount);
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        _burn(key, fee);
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev A swap is charged only on a native-ETH pool and only outside the free hour.
    function _charges(PoolKey calldata key) internal view returns (bool) {
        return key.currency0.isAddressZero() && !isHappyHour();
    }

    /// @dev 1% of `ethAmount`, rounded down.
    function _fee(uint256 ethAmount) internal pure returns (uint256) {
        return ethAmount * FEE_BPS / BPS_DENOMINATOR;
    }

    /// @dev Move `fee` wei from the PoolManager to the dead address and record it. The take debits this
    /// hook inside the manager; the delta the callback returns credits it back by the same amount, so the
    /// hook's net delta is zero once the swap completes and it never holds anything.
    function _burn(PoolKey calldata key, uint256 fee) internal {
        poolManager.take(key.currency0, BURN_ADDRESS, fee);
        emit FeeBurned(key.toId(), fee);
    }

    // ---------------------------------------------------------------------------------------------
    // Callbacks this hook does not declare. Never reached through the PoolManager (the address does not
    // carry their bits); present only to satisfy the interface.
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
