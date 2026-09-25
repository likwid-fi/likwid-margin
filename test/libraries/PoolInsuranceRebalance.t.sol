// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pool} from "../../src/libraries/Pool.sol";
import {toReserves} from "../../src/types/Reserves.sol";
import {InsuranceFunds, toInsuranceFunds} from "../../src/types/InsuranceFunds.sol";

/// Unit tests for Pool.rebalanceInsuranceFunds on a bare pool state
contract PoolInsuranceRebalanceTest is Test {
    using Pool for Pool.State;

    Pool.State private pool;

    function _set(int128 fund0, int128 fund1, uint128 pair0, uint128 pair1) internal {
        pool.insuranceFunds = toInsuranceFunds(fund0, fund1);
        pool.pairReserves = toReserves(pair0, pair1);
    }

    function _assertState(int128 fund0, int128 fund1, uint128 pair0, uint128 pair1) internal view {
        (int128 f0, int128 f1) = pool.insuranceFunds.unpack();
        (uint128 p0, uint128 p1) = pool.pairReserves.reserves();
        assertEq(f0, fund0, "fund0");
        assertEq(f1, fund1, "fund1");
        assertEq(p0, pair0, "pair0");
        assertEq(p1, pair1, "pair1");
    }

    function _assertUntouched(int128 fund0, int128 fund1, uint128 pair0, uint128 pair1) internal {
        _set(fund0, fund1, pair0, pair1);
        (,, uint256 amountOut) = pool.rebalanceInsuranceFunds();
        assertEq(amountOut, 0);
        _assertState(fund0, fund1, pair0, pair1);
    }

    function testSkip_BothPositive() public {
        _assertUntouched(100, 100, 1000, 2000);
    }

    function testSkip_BothNegative() public {
        _assertUntouched(-100, -100, 1000, 2000);
    }

    function testSkip_OneSideZero() public {
        _assertUntouched(-100, 0, 1000, 2000);
        _assertUntouched(0, -100, 1000, 2000);
        _assertUntouched(100, 0, 1000, 2000);
    }

    function testSkip_EmptyPair() public {
        _assertUntouched(-100, 1e18, 0, 0);
        _assertUntouched(-100, 1e18, 1000, 0); // nothing to pay into
        _assertUntouched(-100, 1e18, 1, 2000); // only 1 wei of the bought currency left
    }

    /// Too little surplus to buy even 1 wei: nothing moves.
    function testSkip_OutRoundsToZero() public {
        _assertUntouched(-100, 1, 1000, 2000);
    }

    /// currency1 surplus buys the whole currency0 shortfall on the curve: 2000 * 100 / 900 = 222.2 -> 223.
    function testFill_Currency0Shortfall() public {
        _set(-100, 1e18, 1000, 2000);
        (bool zeroForOne, uint256 amountIn, uint256 amountOut) = pool.rebalanceInsuranceFunds();
        assertFalse(zeroForOne);
        assertEq(amountOut, 100);
        assertEq(amountIn, 223);
        _assertState(0, 1e18 - 223, 900, 2223);
    }

    /// currency0 surplus buys the whole currency1 shortfall on the curve: 1000 * 300 / 1700 = 176.5 -> 177.
    function testFill_Currency1Shortfall() public {
        _set(1e18, -300, 1000, 2000);
        (bool zeroForOne, uint256 amountIn, uint256 amountOut) = pool.rebalanceInsuranceFunds();
        assertTrue(zeroForOne);
        assertEq(amountOut, 300);
        assertEq(amountIn, 177);
        _assertState(1e18 - 177, 0, 1177, 1700);
    }

    /// The pair's share of the price is rounded up.
    function testFill_RoundsInPairsFavour() public {
        _set(-7, 1e18, 3000, 1000); // 1000 * 7 / 2993 = 2.34 -> 3
        (, uint256 amountIn, uint256 amountOut) = pool.rebalanceInsuranceFunds();
        assertEq(amountOut, 7);
        assertEq(amountIn, 3);
        _assertState(0, 1e18 - 3, 2993, 1003);
    }

    /// Not enough surplus: all of it is spent and the shortfall shrinks, rounded down.
    function testPartial_SpendsWholeSurplus() public {
        _set(-1000, 51, 1000, 2000);
        (, uint256 amountIn, uint256 amountOut) = pool.rebalanceInsuranceFunds();
        assertEq(amountIn, 51);
        assertEq(amountOut, 24); // 51 * 1000 / 2051 = 24.9
        _assertState(-976, 0, 976, 2051);
    }

    /// A shortfall as large as the pair's reserve: on the curve the last units cost ever more, so a surplus of the
    /// pair's own size only buys half of it (audit F2: at spot price this left the pair 1 wei).
    function testPartial_LargeShortfallCannotDrainPair() public {
        _set(-5000, 2000, 1000, 2000);
        (, uint256 amountIn, uint256 amountOut) = pool.rebalanceInsuranceFunds();
        assertEq(amountIn, 2000);
        assertEq(amountOut, 500); // 2000 * 1000 / 4000
        _assertState(-4500, 0, 500, 4000);
    }

    /// Only a surplus orders of magnitude above the pair can push it to its last wei.
    function testPartial_HugeSurplusLeavesPairOneWei() public {
        _set(-5000, 1e18, 1000, 2000);
        (, uint256 amountIn, uint256 amountOut) = pool.rebalanceInsuranceFunds();
        assertEq(amountOut, 999);
        assertEq(amountIn, 1_998_000); // 2000 * 999 / 1
        _assertState(-4001, 1e18 - 1_998_000, 1, 2_000_000);
    }

    function testFuzz_ConservesAndNeverReverts(int128 fund0, int128 fund1, uint128 pair0, uint128 pair1) public {
        fund0 = int128(bound(fund0, -1e30, 1e30));
        fund1 = int128(bound(fund1, -1e30, 1e30));
        pair0 = uint128(bound(pair0, 0, 1e30));
        pair1 = uint128(bound(pair1, 0, 1e30));
        _set(fund0, fund1, pair0, pair1);

        (bool zeroForOne,, uint256 amountOut) = pool.rebalanceInsuranceFunds();

        (int128 f0, int128 f1) = pool.insuranceFunds.unpack();
        (uint128 p0, uint128 p1) = pool.pairReserves.reserves();
        // each currency only moves between its fund and its pair reserve
        assertEq(int256(f0) + int256(uint256(p0)), int256(fund0) + int256(uint256(pair0)));
        assertEq(int256(f1) + int256(uint256(p1)), int256(fund1) + int256(uint256(pair1)));
        if (amountOut == 0) {
            assertEq(f0, fund0);
            assertEq(f1, fund1);
            return;
        }
        // only runs across opposite signs, never overshoots either side
        assertTrue((fund0 < 0 && fund1 > 0) || (fund0 > 0 && fund1 < 0));
        (int128 surplusAfter, int128 shortAfter) = zeroForOne ? (f0, f1) : (f1, f0);
        assertGe(surplusAfter, 0);
        assertLe(shortAfter, 0);
        // bought on the curve: k never falls, and the pair keeps at least 1 wei
        assertGe(uint256(p0) * p1, uint256(pair0) * pair1);
        assertGe(zeroForOne ? p1 : p0, 1);
    }
}
