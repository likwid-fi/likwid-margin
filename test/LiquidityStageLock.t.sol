// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LikwidVault} from "../src/LikwidVault.sol";
import {LikwidPairPosition} from "../src/LikwidPairPosition.sol";
import {MarginBase} from "../src/base/MarginBase.sol";
import {LikwidHelper} from "./utils/LikwidHelper.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {Currency} from "../src/types/Currency.sol";
import {MarginState, MarginStateLibrary} from "../src/types/MarginState.sol";
import {StateLibrary} from "../src/libraries/StateLibrary.sol";
import {StageMath} from "../src/libraries/StageMath.sol";
import {Math} from "../src/libraries/Math.sol";

/// @notice The staged liquidity lock in MarginBase, with the vault's default settings: 5 stages of
/// 12 hours, a stage counting as drained once at most 1/5 of it is left. The lock is pool-wide: it
/// throttles how fast liquidity can leave a pool, whoever owns it.
contract LiquidityStageLockTest is Test {
    using PoolIdLibrary for PoolKey;
    using MarginStateLibrary for MarginState;

    LikwidVault vault;
    LikwidPairPosition pairPositionManager;
    LikwidHelper helper;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId poolId;

    uint256 constant STAGE_DURATION = 12 hours;
    uint256 constant STAGE_SIZE = 5;
    uint256 constant AMOUNT = 10e18; // added 1:1, so liquidity == AMOUNT
    uint256 constant INITIAL_LIQUIDITY = 1000; // minted to nobody on the first add, locked with the rest

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        skip(1);
        vault = new LikwidVault(address(this));
        pairPositionManager = new LikwidPairPosition(address(this), vault);
        helper = new LikwidHelper(address(this), vault);

        MockERC20 tokenA = new MockERC20("TokenA", "TKNA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TKNB", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            marginFee: 3000
        });
        poolId = key.toId();
        vault.initialize(key);
    }

    // ==================== helpers ====================

    function _add(address who, uint256 amount) internal returns (uint256 tokenId, uint128 liquidity) {
        token0.mint(who, amount);
        token1.mint(who, amount);
        vm.startPrank(who);
        token0.approve(address(pairPositionManager), type(uint256).max);
        token1.approve(address(pairPositionManager), type(uint256).max);
        (tokenId, liquidity) = pairPositionManager.addLiquidity(key, who, amount, amount, 0, 0, block.timestamp);
        vm.stopPrank();
    }

    function _remove(address who, uint256 tokenId, uint256 liquidity) internal {
        vm.prank(who);
        pairPositionManager.removeLiquidity(tokenId, uint128(liquidity), 0, 0, block.timestamp);
    }

    function _expectLocked(address who, uint256 tokenId, uint256 liquidity) internal {
        vm.prank(who);
        vm.expectRevert(MarginBase.LiquidityLocked.selector);
        pairPositionManager.removeLiquidity(tokenId, uint128(liquidity), 0, 0, block.timestamp);
    }

    function _stages() internal view returns (uint256[] memory) {
        return StateLibrary.getRawStageLiquidities(vault, poolId);
    }

    function _stage(uint256 i) internal view returns (uint128 total, uint128 liquidity) {
        return StageMath.decode(_stages()[i]);
    }

    function _available() internal view returns (uint256) {
        return helper.getReleasedLiquidity(poolId);
    }

    function _positionLiquidity(uint256 tokenId) internal view returns (uint256) {
        return pairPositionManager.getPositionState(tokenId).liquidity;
    }

    // ==================== adding ====================

    function testAdd_SplitsIntoEqualStages() public {
        (, uint128 liquidity) = _add(alice, AMOUNT);
        assertEq(liquidity, AMOUNT);

        uint256 perStage = (AMOUNT + INITIAL_LIQUIDITY) / STAGE_SIZE;
        assertEq(_stages().length, STAGE_SIZE);
        for (uint256 i = 0; i < STAGE_SIZE; i++) {
            (uint128 total, uint128 stageLiquidity) = _stage(i);
            assertEq(total, perStage);
            assertEq(stageLiquidity, perStage);
        }
        assertEq(StateLibrary.getLastStageTimestamp(vault, poolId), vm.getBlockTimestamp());
    }

    function testAdd_LockAmountRoundsUp() public {
        // 10e18 + 1000 + 7 is not divisible by 5: every stage locks the ceiling
        (, uint128 liquidity) = _add(alice, AMOUNT);
        token0.mint(alice, 7);
        token1.mint(alice, 7);
        vm.prank(alice);
        uint128 added = pairPositionManager.increaseLiquidity(1, 7, 7, 0, 0, block.timestamp);
        assertEq(added, 7);

        (uint128 total,) = _stage(0);
        assertEq(total, (AMOUNT + INITIAL_LIQUIDITY) / STAGE_SIZE + 2); // ceil(7 / 5) == 2
        assertGe(uint256(total) * STAGE_SIZE, uint256(liquidity) + added, "stages never lock less than was added");
    }

    function testAdd_TopsUpEveryExistingStage() public {
        _add(alice, AMOUNT);
        (, uint128 bobLiquidity) = _add(bob, AMOUNT);

        uint256 perStage = (AMOUNT + INITIAL_LIQUIDITY) / STAGE_SIZE + Math.ceilDiv(bobLiquidity, STAGE_SIZE);
        assertEq(_stages().length, STAGE_SIZE);
        for (uint256 i = 0; i < STAGE_SIZE; i++) {
            (uint128 total, uint128 stageLiquidity) = _stage(i);
            assertEq(total, perStage);
            assertEq(stageLiquidity, perStage);
        }
    }

    // ==================== removing ====================

    function testRemove_FirstStageIsAvailableImmediately() public {
        (uint256 tokenId,) = _add(alice, AMOUNT);
        uint256 available = _available();
        assertEq(available, (AMOUNT + INITIAL_LIQUIDITY) / STAGE_SIZE);

        _expectLocked(alice, tokenId, available + 1);
        _remove(alice, tokenId, available);

        assertEq(_available(), 0);
        assertEq(_positionLiquidity(tokenId), AMOUNT - available);
        _expectLocked(alice, tokenId, 1);
    }

    function testRemove_NextStageNeedsBothDrainAndDuration() public {
        (uint256 tokenId,) = _add(alice, AMOUNT);
        uint256 perStage = _available();

        // drain the stage down to exactly 1/5: it now counts as free
        _remove(alice, tokenId, perStage - perStage / 5);
        assertEq(_available(), perStage / 5);

        // drained, but the duration has not passed
        skip(STAGE_DURATION - 1);
        assertEq(_available(), perStage / 5);
        _expectLocked(alice, tokenId, perStage / 5 + 1);

        // both conditions met: the next stage opens on top of what is left
        skip(1);
        assertEq(_available(), perStage / 5 + perStage);
    }

    function testRemove_DurationAloneDoesNotOpenNextStage() public {
        (uint256 tokenId,) = _add(alice, AMOUNT);
        uint256 perStage = _available();

        // half drained: more than 1/5 is left, so the stage is not free
        _remove(alice, tokenId, perStage / 2);
        skip(10 * STAGE_DURATION);

        assertEq(_available(), perStage - perStage / 2);
        _expectLocked(alice, tokenId, perStage - perStage / 2 + 1);
    }

    /// Withdrawing from a stage that is not yet drained restarts the clock; once the stage counts
    /// as drained, further withdrawals leave the clock alone.
    function testRemove_ClockRestartsUntilStageIsDrained() public {
        (uint256 tokenId,) = _add(alice, AMOUNT);
        uint256 perStage = _available();
        uint256 t0 = vm.getBlockTimestamp();

        skip(6 hours);
        _remove(alice, tokenId, perStage / 2); // stage was full before this: clock restarts
        assertEq(StateLibrary.getLastStageTimestamp(vault, poolId), t0 + 6 hours);

        skip(1 hours);
        _remove(alice, tokenId, perStage * 35 / 100); // stage was half full before this: restarts again
        assertEq(StateLibrary.getLastStageTimestamp(vault, poolId), t0 + 7 hours);

        skip(1 hours);
        _remove(alice, tokenId, perStage / 20); // stage was already drained (15% left): clock untouched
        assertEq(StateLibrary.getLastStageTimestamp(vault, poolId), t0 + 7 hours);

        // the next stage opens 12h after the last restart, not after the first deposit
        vm.warp(t0 + 7 hours + STAGE_DURATION - 1);
        assertLt(_available(), perStage);
        vm.warp(t0 + 7 hours + STAGE_DURATION);
        assertGt(_available(), perStage);
    }

    function testRemove_AdvancingCarriesLeftoverIntoNextStage() public {
        (uint256 tokenId,) = _add(alice, AMOUNT);
        uint256 perStage = _available();
        uint256 leftover = perStage / 5;

        _remove(alice, tokenId, perStage - leftover);
        skip(STAGE_DURATION);

        // take less than what the old stage still holds: the rest moves into the new front stage
        uint256 taken = leftover / 2;
        _remove(alice, tokenId, taken);

        assertEq(_stages().length, STAGE_SIZE - 1, "old stage popped");
        (uint128 total, uint128 stageLiquidity) = _stage(0);
        assertEq(stageLiquidity, perStage + leftover - taken);
        assertEq(total, perStage + leftover - taken);
        assertEq(StateLibrary.getLastStageTimestamp(vault, poolId), vm.getBlockTimestamp(), "clock restarts on advance");
    }

    function testRemove_AdvancingCanReachIntoNextStage() public {
        (uint256 tokenId,) = _add(alice, AMOUNT);
        uint256 perStage = _available();
        uint256 leftover = perStage / 5;

        _remove(alice, tokenId, perStage - leftover);
        skip(STAGE_DURATION);

        // take the leftover plus half of the next stage in one go
        uint256 taken = leftover + perStage / 2;
        _remove(alice, tokenId, taken);

        assertEq(_stages().length, STAGE_SIZE - 1);
        (uint128 total, uint128 stageLiquidity) = _stage(0);
        assertEq(total, perStage, "total of the new front stage is unchanged");
        assertEq(stageLiquidity, perStage - perStage / 2);
    }

    /// A sole LP leaving as fast as the lock allows: one stage per duration, four waits in total.
    function testRemove_FullExitTakesFourDurations() public {
        (uint256 tokenId,) = _add(alice, AMOUNT);
        uint256 start = vm.getBlockTimestamp();
        uint256 waits;

        while (_positionLiquidity(tokenId) > 0) {
            uint256 take = _available();
            uint256 mine = _positionLiquidity(tokenId);
            if (take > mine) take = mine;
            if (take == 0) {
                skip(STAGE_DURATION);
                waits++;
                assertLe(waits, STAGE_SIZE, "exit must finish");
                continue;
            }
            _remove(alice, tokenId, take);
        }

        assertEq(waits, STAGE_SIZE - 1);
        assertEq(vm.getBlockTimestamp() - start, (STAGE_SIZE - 1) * STAGE_DURATION);
        // everything came back except the share of the permanently locked initial liquidity
        assertEq(token0.balanceOf(alice), AMOUNT - INITIAL_LIQUIDITY);
        assertEq(token1.balanceOf(alice), AMOUNT - INITIAL_LIQUIDITY);
        // only the permanently locked initial liquidity is left, in a single last stage
        assertEq(_stages().length, 1);
        (, uint128 lastLiquidity) = _stage(0);
        assertEq(lastLiquidity, INITIAL_LIQUIDITY);
    }

    /// The lock throttles the pool, not the LP: what one LP takes out of the open stage is no longer
    /// available to anyone else until the next stage opens.
    function testRemove_LockIsPoolWide() public {
        (uint256 aliceId,) = _add(alice, AMOUNT);
        (uint256 bobId,) = _add(bob, AMOUNT);
        uint256 available = _available();

        _remove(alice, aliceId, available);

        _expectLocked(bob, bobId, 1);
        skip(STAGE_DURATION);
        assertGt(_available(), 0);
        _remove(bob, bobId, _available());
    }

    /// Liquidity added while the queue is part-way drained tops up the stages that are left and
    /// appends new ones, so the queue is back to its full length.
    function testAdd_RefillsQueueAfterStagesWerePopped() public {
        (uint256 tokenId,) = _add(alice, AMOUNT);
        for (uint256 i = 0; i < 2; i++) {
            _remove(alice, tokenId, _available());
            skip(STAGE_DURATION);
        }
        _remove(alice, tokenId, 1); // advance past the second drained stage
        uint256 lengthBefore = _stages().length;
        assertLt(lengthBefore, STAGE_SIZE);
        (uint128 frontBefore,) = _stage(0);

        (, uint128 bobLiquidity) = _add(bob, AMOUNT);
        uint256 lockPerStage = Math.ceilDiv(bobLiquidity, STAGE_SIZE);

        assertEq(_stages().length, STAGE_SIZE);
        (uint128 frontAfter,) = _stage(0);
        assertEq(frontAfter, frontBefore + lockPerStage, "existing stage topped up");
        (uint128 appendedTotal, uint128 appendedLiquidity) = _stage(STAGE_SIZE - 1);
        assertEq(appendedTotal, lockPerStage, "appended stage holds only the new lock");
        assertEq(appendedLiquidity, lockPerStage);
    }

    // ==================== configuration ====================

    function testDisabled_EverythingIsFree() public {
        vault.setMarginState(vault.marginState().setStageDuration(0));
        (uint256 tokenId,) = _add(alice, AMOUNT);

        assertEq(_stages().length, 0, "nothing is queued while the lock is off");
        assertEq(_available(), type(uint128).max);
        _remove(alice, tokenId, AMOUNT);
        assertEq(_positionLiquidity(tokenId), 0);
    }

    /// Liquidity added while the lock was off was never queued, so it stays free after the lock is
    /// switched on; only later additions are staged.
    function testEnabledLater_EarlierLiquidityStaysFree() public {
        MarginState enabled = vault.marginState();
        vault.setMarginState(enabled.setStageDuration(0));
        (uint256 tokenId,) = _add(alice, AMOUNT);

        vault.setMarginState(enabled);
        assertEq(_available(), type(uint128).max);
        _remove(alice, tokenId, AMOUNT / 2);

        // once something is queued, the queue governs every withdrawal, including alice's
        (, uint128 bobLiquidity) = _add(bob, AMOUNT);
        assertEq(_available(), Math.ceilDiv(bobLiquidity, STAGE_SIZE));
        _expectLocked(alice, tokenId, AMOUNT / 2);
    }

    /// Footgun when the lock is switched on for a pool that already has liquidity: that liquidity was
    /// never queued, so the stages only ever release as much as was added afterwards. Once they are
    /// used up the rest cannot leave until the owner switches the lock off again.
    function testEnabledLater_UnqueuedLiquidityExitsOnlyWithLockOff() public {
        MarginState enabled = vault.marginState();
        vault.setMarginState(enabled.setStageDuration(0));
        (uint256 aliceId,) = _add(alice, AMOUNT);
        vault.setMarginState(enabled);
        (uint256 bobId, uint128 bobLiquidity) = _add(bob, AMOUNT);

        // bob leaves through the stages: they release exactly what was queued, i.e. his liquidity
        uint256 guard;
        while (_positionLiquidity(bobId) > 0) {
            uint256 take = _available();
            uint256 mine = _positionLiquidity(bobId);
            if (take > mine) take = mine;
            if (take == 0) skip(STAGE_DURATION);
            else _remove(bob, bobId, take);
            assertLt(++guard, 50);
        }
        assertEq(uint256(bobLiquidity), AMOUNT + INITIAL_LIQUIDITY);

        // alice's liquidity is still in the pool, but no amount of waiting opens anything for it
        assertEq(_positionLiquidity(aliceId), AMOUNT);
        skip(100 * STAGE_DURATION);
        assertLt(_available(), STAGE_SIZE, "only rounding dust is left in the queue");
        _expectLocked(alice, aliceId, AMOUNT);

        // the owner can release it by switching the lock off
        vault.setMarginState(enabled.setStageDuration(0));
        _remove(alice, aliceId, AMOUNT);
        assertEq(_positionLiquidity(aliceId), 0);
    }
}
