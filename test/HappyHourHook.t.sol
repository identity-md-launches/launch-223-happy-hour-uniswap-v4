// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HappyHourHook} from "../src/HappyHourHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HappyHourFixture} from "./utils/HappyHourFixture.sol";

contract HappyHourHookTest is HappyHourFixture {
    using PoolIdLibrary for PoolKey;

    event FeeBurned(PoolId indexed poolId, uint256 amount);

    // ---------------------------------------------------------------------------------------------
    // Constructor and permissions
    // ---------------------------------------------------------------------------------------------

    function test_constructor_setsPoolManager() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.HAPPY_HOUR);
        assertEq(HookFlags.HAPPY_HOUR, 0xCC);
    }

    function test_constructor_rejectsZeroPoolManager() public {
        // At an address carrying the right bits, so the only thing wrong is the manager.
        (, bytes32 salt) = HookMiner.find(
            address(this), HookFlags.HAPPY_HOUR, type(HappyHourHook).creationCode, abi.encode(address(0))
        );
        vm.expectRevert(HappyHourHook.ZeroPoolManager.selector);
        new HappyHourHook{salt: salt}(IPoolManager(address(0)));
    }

    function test_constructor_rejectsZeroPoolManagerBeforeCheckingAddress() public {
        // A plain CREATE address does not carry the bits either; the zero manager is still reported first.
        vm.expectRevert(HappyHourHook.ZeroPoolManager.selector);
        new HappyHourHook(IPoolManager(address(0)));
    }

    function test_constructor_rejectsAddressWithoutFlags() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertFalse(HookFlags.matches(predicted, HookFlags.HAPPY_HOUR), "test needs a non-matching address");
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new HappyHourHook(manager);
    }

    function test_constructor_rejectsPartialFlags() public {
        uint160 wrong = HookFlags.BEFORE_SWAP | HookFlags.BEFORE_SWAP_RETURN_DELTA; // afterSwap bits missing
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), wrong, type(HappyHourHook).creationCode, abi.encode(manager));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new HappyHourHook{salt: salt}(manager);
    }

    function test_constructor_rejectsExtraFlags() public {
        uint160 wrong = HookFlags.HAPPY_HOUR | HookFlags.BEFORE_INITIALIZE;
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), wrong, type(HappyHourHook).creationCode, abi.encode(manager));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new HappyHourHook{salt: salt}(manager);
    }

    function test_permissions_onlySwapCallbacks() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_callbacks_refuseNonManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, 0);
        vm.expectRevert(HappyHourHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(HappyHourHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function test_callbacks_refuseNonManagerEvenAsPrankedRouter() public {
        SwapParams memory params = SwapParams(true, -1 ether, 0);
        vm.prank(address(swapRouter));
        vm.expectRevert(HappyHourHook.NotPoolManager.selector);
        hook.beforeSwap(address(swapRouter), key, params, "");
    }

    function test_undeclaredCallbacks_revert() public {
        vm.expectRevert(HappyHourHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(HappyHourHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
    }

    // ---------------------------------------------------------------------------------------------
    // Four swap shapes outside the free hour: exactly 1% of the ETH side vs. the hookless reference
    // ---------------------------------------------------------------------------------------------

    function test_buyExactIn_charges1pctOfEthIn() public {
        uint256 ethIn = 10 ether;
        uint256 fee = pct1(ethIn);
        uint256 deadBefore = DEAD.balance;

        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeBurned(key.toId(), fee);
        BalanceDelta d = buyExactIn(key, ethIn);
        // Reference pool swapping the net amount yields exactly the same tokens: the 1% simply never
        // reached the pool.
        BalanceDelta r = buyExactIn(refKey, ethIn - fee);

        assertEq(d.amount0(), -int256(ethIn), "user pays exactly what was specified");
        assertEq(d.amount1(), r.amount1(), "tokens out match reference for the net ETH");
        assertEq(DEAD.balance - deadBefore, fee, "burned exactly 1% of ETH in");
        assertHookHoldsNothing();
    }

    function test_buyExactIn_vsReferenceSameParams() public {
        uint256 ethIn = 10 ether;
        BalanceDelta d = buyExactIn(key, ethIn);
        BalanceDelta r = buyExactIn(refKey, ethIn);
        assertEq(d.amount0(), r.amount0(), "ETH side identical");
        assertLt(d.amount1(), r.amount1(), "fewer tokens for the same ETH");
        assertGt(d.amount1(), 0);
    }

    function test_buyExactOut_charges1pctOfEthIn() public {
        uint256 tokensOut = 10 ether;
        BalanceDelta r = buyExactOut(refKey, tokensOut, 100 ether);
        uint256 ethRef = abs0(r);
        uint256 fee = pct1(ethRef);
        uint256 deadBefore = DEAD.balance;

        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeBurned(key.toId(), fee);
        BalanceDelta d = buyExactOut(key, tokensOut, 100 ether);

        assertEq(d.amount1(), int256(tokensOut), "receives exactly the specified tokens");
        assertEq(d.amount1(), r.amount1());
        assertEq(abs0(d), ethRef + fee, "pays reference ETH plus 1%");
        assertEq(DEAD.balance - deadBefore, fee, "burned exactly 1% of the pool's ETH in");
        assertHookHoldsNothing();
    }

    function test_sellExactIn_charges1pctOfEthOut() public {
        uint256 tokensIn = 10 ether;
        BalanceDelta r = sellExactIn(refKey, tokensIn);
        uint256 ethRef = abs0(r);
        uint256 fee = pct1(ethRef);
        uint256 deadBefore = DEAD.balance;
        uint256 userBefore = address(this).balance;

        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeBurned(key.toId(), fee);
        BalanceDelta d = sellExactIn(key, tokensIn);

        assertEq(d.amount1(), -int256(tokensIn));
        assertEq(d.amount1(), r.amount1());
        assertEq(abs0(d), ethRef - fee, "receives reference ETH minus 1%");
        assertEq(address(this).balance - userBefore, ethRef - fee, "ETH actually arrived");
        assertEq(DEAD.balance - deadBefore, fee, "burned exactly 1% of the pool's ETH out");
        assertHookHoldsNothing();
    }

    function test_sellExactOut_charges1pctOfEthOut() public {
        uint256 ethOut = 10 ether;
        uint256 fee = pct1(ethOut);
        uint256 deadBefore = DEAD.balance;
        uint256 userBefore = address(this).balance;

        vm.expectEmit(true, false, false, true, address(hook));
        emit FeeBurned(key.toId(), fee);
        BalanceDelta d = sellExactOut(key, ethOut);
        uint256 received = address(this).balance - userBefore;
        // The pool had to produce ethOut + fee, so the token cost equals the reference cost of that amount.
        BalanceDelta r = sellExactOut(refKey, ethOut + fee);

        assertEq(d.amount0(), int256(ethOut), "receives exactly the specified ETH");
        assertEq(received, ethOut, "ETH actually arrived");
        assertEq(d.amount1(), r.amount1(), "token cost matches reference for the gross ETH");
        assertEq(DEAD.balance - deadBefore, fee, "burned exactly 1% of ETH out");
        assertHookHoldsNothing();
    }

    function test_sellExactOut_vsReferenceSameParams() public {
        uint256 ethOut = 10 ether;
        BalanceDelta d = sellExactOut(key, ethOut);
        BalanceDelta r = sellExactOut(refKey, ethOut);
        assertEq(d.amount0(), r.amount0(), "ETH side identical");
        assertLt(d.amount1(), r.amount1(), "costs more tokens (both negative)");
    }

    function test_feeRoundsDown_andSkipsDust() public {
        // 150 wei -> fee 1 wei; 99 wei -> fee 0, no event, nothing burned.
        uint256 deadBefore = DEAD.balance;
        buyExactIn(key, 150);
        assertEq(DEAD.balance - deadBefore, 1);

        deadBefore = DEAD.balance;
        vm.recordLogs();
        buyExactIn(key, 99);
        assertEq(DEAD.balance - deadBefore, 0);
        assertNoFeeBurnedLog();
        assertHookHoldsNothing();
    }

    function test_consecutiveSwapsAccumulateAtDead() public {
        uint256 deadBefore = DEAD.balance;
        buyExactIn(key, 1 ether);
        buyExactIn(key, 2 ether);
        sellExactOut(key, 1 ether);
        assertEq(DEAD.balance - deadBefore, pct1(1 ether) + pct1(2 ether) + pct1(1 ether));
        assertHookHoldsNothing();
    }

    // ---------------------------------------------------------------------------------------------
    // Inside the free hour: no fee, identical to the reference
    // ---------------------------------------------------------------------------------------------

    function test_happyHour_buyExactIn_isFree() public {
        warpToHappyHour(DAY_100);
        assertNoFee(buyExactIn(key, 10 ether), buyExactIn(refKey, 10 ether));
    }

    function test_happyHour_buyExactOut_isFree() public {
        warpToHappyHour(DAY_100);
        assertNoFee(buyExactOut(key, 10 ether, 100 ether), buyExactOut(refKey, 10 ether, 100 ether));
    }

    function test_happyHour_sellExactIn_isFree() public {
        warpToHappyHour(DAY_100);
        assertNoFee(sellExactIn(key, 10 ether), sellExactIn(refKey, 10 ether));
    }

    function test_happyHour_sellExactOut_isFree() public {
        warpToHappyHour(DAY_100);
        assertNoFee(sellExactOut(key, 10 ether), sellExactOut(refKey, 10 ether));
    }

    function test_happyHour_emitsNothing() public {
        warpToHappyHour(DAY_100);
        vm.recordLogs();
        buyExactIn(key, 10 ether);
        assertNoFeeBurnedLog();
    }

    function assertNoFee(BalanceDelta d, BalanceDelta r) internal view {
        assertEq(d.amount0(), r.amount0(), "ETH side differs from hookless pool");
        assertEq(d.amount1(), r.amount1(), "token side differs from hookless pool");
        assertEq(DEAD.balance, 0, "something was burned");
        assertHookHoldsNothing();
    }

    function assertNoFeeBurnedLog() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].emitter != address(hook) || logs[i].topics.length == 0
                    || logs[i].topics[0] != FeeBurned.selector,
                "FeeBurned emitted"
            );
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Boundaries: first and last second of the free hour, and one second either side
    // ---------------------------------------------------------------------------------------------

    function test_boundary_secondBeforeStart_charges() public {
        vm.warp(hook.happyHourStart(DAY_100) - 1);
        assertFalse(hook.isHappyHour());
        assertEq(hook.currentFeeBps(), 100);
        assertBurns(1 ether, pct1(1 ether));
    }

    function test_boundary_firstSecond_isFree() public {
        vm.warp(hook.happyHourStart(DAY_100));
        assertTrue(hook.isHappyHour());
        assertEq(hook.currentFeeBps(), 0);
        assertBurns(1 ether, 0);
    }

    function test_boundary_lastSecond_isFree() public {
        vm.warp(hook.happyHourStart(DAY_100) + 3599);
        assertTrue(hook.isHappyHour());
        assertEq(hook.currentFeeBps(), 0);
        assertBurns(1 ether, 0);
    }

    function test_boundary_secondAfterEnd_charges() public {
        vm.warp(hook.happyHourStart(DAY_100) + 3600);
        assertFalse(hook.isHappyHour());
        assertEq(hook.currentFeeBps(), 100);
        assertBurns(1 ether, pct1(1 ether));
    }

    function test_boundary_hourZero_dayStart() public {
        // Day 24 starts its free hour at UTC hour 0: the very first second of the day is free, and the
        // last second of day 23 (free hour at 17:00) is not.
        uint256 day = 24;
        assertEq(hook.happyHourStart(day), day * 86_400);
        vm.warp(day * 86_400 - 1);
        assertFalse(hook.isHappyHour());
        vm.warp(day * 86_400);
        assertTrue(hook.isHappyHour());
        vm.warp(day * 86_400 + 3600);
        assertFalse(hook.isHappyHour());
    }

    function test_boundary_hour23_runsToDayEnd() public {
        // Day 17 starts its free hour at UTC hour 23; it ends exactly at the day boundary.
        uint256 day = 17;
        assertEq(hook.happyHourStart(day), day * 86_400 + 23 hours);
        vm.warp(day * 86_400 + 23 hours - 1);
        assertFalse(hook.isHappyHour());
        vm.warp(day * 86_400 + 23 hours);
        assertTrue(hook.isHappyHour());
        vm.warp((day + 1) * 86_400 - 1);
        assertTrue(hook.isHappyHour());
        vm.warp((day + 1) * 86_400);
        assertFalse(hook.isHappyHour(), "day 18 starts at hour 6, not 0");
    }

    function assertBurns(uint256 ethIn, uint256 expectedFee) internal {
        uint256 deadBefore = DEAD.balance;
        buyExactIn(key, ethIn);
        assertEq(DEAD.balance - deadBefore, expectedFee);
        assertHookHoldsNothing();
    }

    // ---------------------------------------------------------------------------------------------
    // Schedule
    // ---------------------------------------------------------------------------------------------

    function test_schedule_consecutiveDays() public view {
        // Hours advance by 7 each day, modulo 24: 0, 7, 14, 21, 4, 11, 18, 1, ...
        uint8[24] memory hours_ = [0, 7, 14, 21, 4, 11, 18, 1, 8, 15, 22, 5, 12, 19, 2, 9, 16, 23, 6, 13, 20, 3, 10, 17];
        for (uint256 day = 0; day < 72; day++) {
            uint256 expectedHour = hours_[day % 24];
            assertEq(hook.happyHourStart(day), day * 86_400 + expectedHour * 3600, "day schedule");
            assertEq((hook.happyHourStart(day) % 86_400) / 3600, expectedHour);
        }
    }

    function test_schedule_wrapsFrom23() public view {
        assertEq((hook.happyHourStart(17) % 86_400) / 3600, 23);
        assertEq((hook.happyHourStart(18) % 86_400) / 3600, 6);
        assertEq((hook.happyHourStart(23) % 86_400) / 3600, 17);
        assertEq((hook.happyHourStart(24) % 86_400) / 3600, 0, "cycle returns to hour 0");
        assertEq((hook.happyHourStart(3) % 86_400) / 3600, 21);
        assertEq((hook.happyHourStart(4) % 86_400) / 3600, 4, "21 + 7 wraps to 4");
    }

    function test_schedule_realDate() public view {
        // 2026-09-27 00:00:00 UTC = 1790467200 = day 20723. 20723 * 7 % 24 = 145061 % 24 = 5.
        uint256 day = 1_790_467_200 / 86_400;
        assertEq(day, 20_723);
        assertEq(hook.happyHourStart(day), 1_790_467_200 + 5 hours);
    }

    function test_nextHappyHour_beforeTodays() public {
        vm.warp(hook.happyHourStart(DAY_100) - 10);
        assertEq(hook.nextHappyHour(), hook.happyHourStart(DAY_100));
    }

    function test_nextHappyHour_duringTodays_pointsToTomorrow() public {
        vm.warp(hook.happyHourStart(DAY_100) + 100);
        assertEq(hook.nextHappyHour(), hook.happyHourStart(DAY_100 + 1));
        assertGt(hook.nextHappyHour(), block.timestamp);
    }

    function test_nextHappyHour_afterTodays_pointsToTomorrow() public {
        vm.warp(NOON_DAY_100);
        assertEq(hook.nextHappyHour(), hook.happyHourStart(DAY_100 + 1));
        assertEq(hook.nextHappyHour(), (DAY_100 + 1) * 86_400 + 11 hours);
    }

    function test_nextHappyHour_atExactStart_pointsToTomorrow() public {
        vm.warp(hook.happyHourStart(DAY_100));
        assertEq(hook.nextHappyHour(), hook.happyHourStart(DAY_100 + 1));
    }

    function test_currentFeeBps_matchesIsHappyHour() public {
        vm.warp(NOON_DAY_100);
        assertEq(hook.currentFeeBps(), 100);
        assertFalse(hook.isHappyHour());
        warpToHappyHour(DAY_100);
        assertEq(hook.currentFeeBps(), 0);
        assertTrue(hook.isHappyHour());
    }

    // ---------------------------------------------------------------------------------------------
    // Pools not paired with native ETH are untouched
    // ---------------------------------------------------------------------------------------------

    function test_erc20Pool_isUntouched() public {
        MockERC20 a = new MockERC20("A", "A", 1_000_000 ether);
        MockERC20 b = new MockERC20("B", "B", 1_000_000 ether);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);

        PoolKey memory k = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), LP_FEE, TICK_SPACING, hook);
        PoolKey memory rk =
            PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), LP_FEE, TICK_SPACING, IHooks(address(0)));
        manager.initialize(k, SQRT_PRICE_1_1);
        manager.initialize(rk, SQRT_PRICE_1_1);
        addLiquidity(k, LIQUIDITY);
        addLiquidity(rk, LIQUIDITY);

        uint256 deadBefore = DEAD.balance;
        vm.recordLogs();
        assertSame(swap(k, true, -10 ether, 0), swap(rk, true, -10 ether, 0));
        assertSame(swap(k, true, 10 ether, 0), swap(rk, true, 10 ether, 0));
        assertSame(swap(k, false, -10 ether, 0), swap(rk, false, -10 ether, 0));
        assertSame(swap(k, false, 10 ether, 0), swap(rk, false, 10 ether, 0));
        assertNoFeeBurnedLog();
        assertEq(DEAD.balance, deadBefore);
        assertEq(t0.balanceOf(address(hook)), 0);
        assertEq(t1.balanceOf(address(hook)), 0);
        assertEq(t0.balanceOf(DEAD), 0);
        assertEq(t1.balanceOf(DEAD), 0);
        assertHookHoldsNothing();
    }

    function assertSame(BalanceDelta d, BalanceDelta r) internal pure {
        assertEq(d.amount0(), r.amount0());
        assertEq(d.amount1(), r.amount1());
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    /// @dev Any swap shape, any size within the pool's depth, any timestamp: the burn is exactly 1% of the
    /// reference pool's ETH leg outside the free hour and exactly 0 inside, and the hook never holds funds.
    function testFuzz_feeAcrossShapesAndTimestamps(uint8 shape, uint256 amount, uint48 timestamp) public {
        shape = uint8(bound(shape, 0, 3));
        amount = bound(amount, 1000, 50 ether);
        vm.warp(timestamp);

        uint256 day = uint256(timestamp) / 86_400;
        uint256 start = day * 86_400 + ((day * 7) % 24) * 3600;
        bool free = timestamp >= start && timestamp < start + 3600;
        assertEq(hook.isHappyHour(), free, "isHappyHour vs formula");
        assertEq(hook.currentFeeBps(), free ? 0 : 100);

        uint256 deadBefore = DEAD.balance;
        BalanceDelta d;
        BalanceDelta r;
        uint256 expectedFee;
        if (shape == 0) {
            r = buyExactIn(refKey, amount);
            d = buyExactIn(key, amount);
            expectedFee = free ? 0 : pct1(amount);
            assertEq(d.amount0(), r.amount0(), "exact-in buy: ETH side equal");
        } else if (shape == 1) {
            r = buyExactOut(refKey, amount, 200 ether);
            d = buyExactOut(key, amount, 200 ether);
            expectedFee = free ? 0 : pct1(abs0(r));
            assertEq(d.amount1(), r.amount1(), "exact-out buy: token side equal");
            assertEq(abs0(d), abs0(r) + expectedFee, "exact-out buy: ETH side plus fee");
        } else if (shape == 2) {
            r = sellExactIn(refKey, amount);
            d = sellExactIn(key, amount);
            expectedFee = free ? 0 : pct1(abs0(r));
            assertEq(d.amount1(), r.amount1(), "exact-in sell: token side equal");
            assertEq(abs0(d), abs0(r) - expectedFee, "exact-in sell: ETH side minus fee");
        } else {
            r = sellExactOut(refKey, amount);
            d = sellExactOut(key, amount);
            expectedFee = free ? 0 : pct1(amount);
            assertEq(d.amount0(), r.amount0(), "exact-out sell: ETH side equal");
        }
        if (free) assertSame(d, r);
        assertEq(DEAD.balance - deadBefore, expectedFee, "burned amount");
        assertHookHoldsNothing();
    }

    function testFuzz_schedule(uint256 day) public {
        day = bound(day, 1, 10_000_000);
        uint256 start = hook.happyHourStart(day);
        assertEq(start, day * 86_400 + ((day * 7) % 24) * 3600);
        assertEq(start / 86_400, day, "start lies inside its own day");

        vm.warp(start - 1);
        assertFalse(hook.isHappyHour());
        assertEq(hook.nextHappyHour(), start);
        vm.warp(start);
        assertTrue(hook.isHappyHour());
        assertEq(hook.nextHappyHour(), hook.happyHourStart(day + 1));
        vm.warp(start + 3599);
        assertTrue(hook.isHappyHour());
        vm.warp(start + 3600);
        assertFalse(hook.isHappyHour());
        assertEq(hook.nextHappyHour(), hook.happyHourStart(day + 1));
        assertGt(hook.nextHappyHour(), block.timestamp);
    }

    function testFuzz_exactlyOneFreeHourPerDay(uint256 day) public {
        day = bound(day, 0, 1_000_000);
        uint256 freeSeconds;
        // Sample every 60 seconds across the day: a 3600-second window contributes exactly 60 samples.
        for (uint256 t = day * 86_400; t < (day + 1) * 86_400; t += 60) {
            vm.warp(t);
            if (hook.isHappyHour()) freeSeconds += 60;
        }
        assertEq(freeSeconds, 3600);
    }
}
