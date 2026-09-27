// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HappyHourHook} from "../../src/HappyHourHook.sol";
import {HappyHourToken} from "../../src/HappyHourToken.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared scaffolding: one PoolManager, the hook at a mined address, a native-ETH/HAPPY pool with the
/// hook and an identical hookless reference pool, both seeded with the same full-range liquidity.
abstract contract HappyHourFixture is Test {
    using CurrencyLibrary for Currency;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant MIN_TICK = -887_220;
    int24 internal constant MAX_TICK = 887_220;
    uint24 internal constant LP_FEE = 3_000;
    uint128 internal constant LIQUIDITY = 1_000 ether;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev Day 100 starts its free hour at UTC hour (700 % 24) = 4. Noon on that day is well outside it.
    uint256 internal constant DAY_100 = 100;
    uint256 internal constant NOON_DAY_100 = DAY_100 * 86_400 + 12 hours;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    HappyHourToken internal token;
    HappyHourHook internal hook;

    PoolKey internal key;
    PoolKey internal refKey;

    receive() external payable {}

    function setUp() public virtual {
        vm.warp(NOON_DAY_100);

        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        token = new HappyHourToken();
        hook = deployHook(manager);

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        refKey = key;
        refKey.hooks = IHooks(address(0));

        manager.initialize(key, SQRT_PRICE_1_1);
        manager.initialize(refKey, SQRT_PRICE_1_1);

        vm.deal(address(this), 1_000_000 ether);
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);

        addLiquidity(key, LIQUIDITY);
        addLiquidity(refKey, LIQUIDITY);
    }

    /// @dev Deploys the hook through CREATE2 from this contract at an address carrying its flags.
    function deployHook(IPoolManager pm) internal returns (HappyHourHook deployed) {
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HookFlags.HAPPY_HOUR, type(HappyHourHook).creationCode, abi.encode(pm));
        deployed = new HappyHourHook{salt: salt}(pm);
        assertEq(address(deployed), predicted, "mined address");
    }

    function addLiquidity(PoolKey memory k, uint128 liquidity) internal {
        uint256 value = k.currency0.isAddressZero() ? uint256(liquidity) + 1 ether : 0;
        lpRouter.modifyLiquidity{value: value}(
            k,
            ModifyLiquidityParams({
                tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );
    }

    /// @dev Runs a swap through the router. `ethBudget` is the ETH sent along for buys; the router refunds
    /// whatever the swap did not use.
    function swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified, uint256 ethBudget)
        internal
        returns (BalanceDelta delta)
    {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        uint256 value = (zeroForOne && k.currency0.isAddressZero()) ? ethBudget : 0;
        delta = swapRouter.swap{value: value}(
            k, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
    }

    // Convenience wrappers for the four shapes on ETH pools.

    function buyExactIn(PoolKey memory k, uint256 ethIn) internal returns (BalanceDelta) {
        return swap(k, true, -int256(ethIn), ethIn);
    }

    function buyExactOut(PoolKey memory k, uint256 tokensOut, uint256 ethBudget) internal returns (BalanceDelta) {
        return swap(k, true, int256(tokensOut), ethBudget);
    }

    function sellExactIn(PoolKey memory k, uint256 tokensIn) internal returns (BalanceDelta) {
        return swap(k, false, -int256(tokensIn), 0);
    }

    function sellExactOut(PoolKey memory k, uint256 ethOut) internal returns (BalanceDelta) {
        return swap(k, false, int256(ethOut), 0);
    }

    function assertHookHoldsNothing() internal view {
        assertEq(address(hook).balance, 0, "hook holds ETH");
        assertEq(token.balanceOf(address(hook)), 0, "hook holds HAPPY");
        assertEq(manager.balanceOf(address(hook), 0), 0, "hook holds ETH claims");
        assertEq(manager.balanceOf(address(hook), uint160(address(token))), 0, "hook holds HAPPY claims");
    }

    function pct1(uint256 amount) internal pure returns (uint256) {
        return amount / 100;
    }

    function abs0(BalanceDelta d) internal pure returns (uint256) {
        int256 a = d.amount0();
        return a < 0 ? uint256(-a) : uint256(a);
    }

    function abs1(BalanceDelta d) internal pure returns (uint256) {
        int256 a = d.amount1();
        return a < 0 ? uint256(-a) : uint256(a);
    }

    function warpToHappyHour(uint256 day) internal {
        vm.warp(hook.happyHourStart(day));
    }

    function warpOutsideHappyHour(uint256 day) internal {
        // 1 second after the free hour ends is outside for that day and cannot be inside the next day's.
        vm.warp(hook.happyHourStart(day) + 3600);
    }
}
