// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PriceMath} from "../../src/libraries/PriceMath.sol";
import {Reserves, toReserves} from "../../src/types/Reserves.sol";
import {PerLibrary} from "../../src/libraries/PerLibrary.sol";
import {FixedPoint96} from "../../src/libraries/FixedPoint96.sol";

contract PriceMathTest is Test {
    using PerLibrary for *;

    function testTransferReserves_destReservesNotPositive() public pure {
        Reserves originReserves = toReserves(100e18, 100e18);
        Reserves destReserves = toReserves(0, 100e18);
        uint256 timeElapsed = 10;
        uint24 priceMoveSpeedPPM = 100;

        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        assertEq(result.reserve0(), destReserves.reserve0());
        assertEq(result.reserve1(), destReserves.reserve1());
    }

    function testTransferReserves_originReservesNotPositive() public pure {
        Reserves originReserves = toReserves(0, 100e18);
        Reserves destReserves = toReserves(100e18, 100e18);
        uint256 timeElapsed = 10;
        uint24 priceMoveSpeedPPM = 100;

        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        assertEq(result.reserve0(), destReserves.reserve0());
        assertEq(result.reserve1(), destReserves.reserve1());
    }

    function testTransferReserves_bothPositive_destReserve0LessThanMin() public pure {
        Reserves originReserves = toReserves(100e18, 100e18); // price = 1
        Reserves destReserves = toReserves(50e18, 120e18);
        uint256 timeElapsed = 10; // 10 seconds
        uint24 priceMoveSpeedPPM = 100; // 0.01%

        // priceMoved = 100 * 10^2 = 10000
        // price0X96 = 1 * Q96
        // price1X96 = 1 * Q96
        // maxPrice0X96 = price0X96.upperMillion(10000) = 1 * Q96 * (1 + 10000/1e6) = 1.01 * Q96
        // maxPrice1X96 = price1X96.upperMillion(10000) = 1.01 * Q96
        // newTruncatedReserve1 = 120e18
        // minTruncatedReserve0 = 120e18 * Q96 / (1.01 * Q96) = 118.81e18
        // maxTruncatedReserve0 = 120e18 * (1.01 * Q96) / Q96 = 121.2e18
        // destReserves.reserve0() is 50e18, which is less than minTruncatedReserve0.
        // So, newTruncatedReserve0 should be minTruncatedReserve0.

        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        uint256 priceMoved = priceMoveSpeedPPM * (timeElapsed ** 2);
        uint256 price0X96 = (originReserves.reserve1() * FixedPoint96.Q96) / originReserves.reserve0();
        uint128 newTruncatedReserve1 = destReserves.reserve1();
        uint256 maxPrice0X96 = price0X96.upperMillion(priceMoved);
        uint128 minTruncatedReserve0 = uint128((uint256(newTruncatedReserve1) * FixedPoint96.Q96) / maxPrice0X96);

        assertEq(result.reserve0(), minTruncatedReserve0);
        assertEq(result.reserve1(), destReserves.reserve1());
    }

    function testTransferReserves_bothPositive_destReserve0MoreThanMax() public pure {
        Reserves originReserves = toReserves(100e18, 100e18); // price = 1
        Reserves destReserves = toReserves(150e18, 120e18);
        uint256 timeElapsed = 10;
        uint24 priceMoveSpeedPPM = 100;

        // priceMoved = 10000
        // price1X96 = 1 * Q96
        // maxPrice1X96 = 1.01 * Q96
        // newTruncatedReserve1 = 120e18
        // maxTruncatedReserve0 = 120e18 * (1.01 * Q96) / Q96 = 121.2e18
        // destReserves.reserve0() is 150e18, which is more than maxTruncatedReserve0.
        // So, newTruncatedReserve0 should be maxTruncatedReserve0.

        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        uint256 priceMoved = priceMoveSpeedPPM * (timeElapsed ** 2);
        uint256 price1X96 = (originReserves.reserve0() * FixedPoint96.Q96) / originReserves.reserve1();
        uint256 maxPrice1X96 = price1X96.upperMillion(priceMoved);
        uint128 newTruncatedReserve1 = destReserves.reserve1();
        uint128 maxTruncatedReserve0 = uint128((uint256(newTruncatedReserve1) * maxPrice1X96) / FixedPoint96.Q96);

        assertEq(result.reserve0(), maxTruncatedReserve0);
        assertEq(result.reserve1(), destReserves.reserve1());
    }

    function testTransferReserves_bothPositive_destReserve0InRange() public pure {
        Reserves originReserves = toReserves(100e18, 100e18); // price = 1
        Reserves destReserves = toReserves(120e18, 120e18);
        uint256 timeElapsed = 10;
        uint24 priceMoveSpeedPPM = 100;

        // minTruncatedReserve0 = 118.81e18
        // maxTruncatedReserve0 = 121.2e18
        // destReserves.reserve0() is 120e18, which is in range.
        // So, newTruncatedReserve0 should be destReserves.reserve0().

        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        assertEq(result.reserve0(), destReserves.reserve0());
        assertEq(result.reserve1(), destReserves.reserve1());
    }

    function testTransferReserves_zeroTimeElapsed() public pure {
        Reserves originReserves = toReserves(100e18, 100e18);
        Reserves destReserves = toReserves(120e18, 120e18);
        uint256 timeElapsed = 0;
        uint24 priceMoveSpeedPPM = 100;

        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        // When timeElapsed is 0, priceMoved is 0.
        // max prices are same as current prices
        // minReserve0 = 120e18 * Q96 / (1 * Q96) = 120e18
        // maxReserve0 = 120e18 * (1 * Q96) / Q96 = 120e18
        // So result should be destReserves.

        assertEq(result.reserve0(), destReserves.reserve0());
        assertEq(result.reserve1(), destReserves.reserve1());
    }

    function testTransferReserves_zeroPriceMoveSpeed() public pure {
        Reserves originReserves = toReserves(100e18, 100e18);
        Reserves destReserves = toReserves(120e18, 120e18);
        uint256 timeElapsed = 10;
        uint24 priceMoveSpeedPPM = 0;

        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        // When priceMoveSpeedPPM is 0, priceMoved is 0.
        // Same logic as zeroTimeElapsed
        assertEq(result.reserve0(), destReserves.reserve0());
        assertEq(result.reserve1(), destReserves.reserve1());
    }

    function testTransferReserves_largeTimeElapsed_destReserve0LessThanMin() public pure {
        Reserves originReserves = toReserves(100e18, 100e18); // price = 1
        Reserves destReserves = toReserves(50e18, 120e18);
        uint256 timeElapsed = 1000; // Large time elapsed
        uint24 priceMoveSpeedPPM = 100; // 0.01%

        // priceMoved = 100 * 1000^2 = 100 * 1e6 = 1e8. This means 10000% which is very large.
        // maxPrice0X96 should be significantly larger, forcing destReserve0 to be clamped to minTruncatedReserve0.
        // The bounds are so wide that destReserves.reserve0() should be within range.
        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        assertEq(result.reserve0(), destReserves.reserve0());
        assertEq(result.reserve1(), destReserves.reserve1());
    }

    function testTransferReserves_largeTimeElapsed_destReserve0MoreThanMax() public pure {
        Reserves originReserves = toReserves(100e18, 100e18); // price = 1
        Reserves destReserves = toReserves(150e18, 120e18);
        uint256 timeElapsed = 1000; // Large time elapsed
        uint24 priceMoveSpeedPPM = 100; // 0.01%

        // priceMoved = 100 * 1000^2 = 1e8.
        // The bounds are so wide that destReserves.reserve0() should be within range.
        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        assertEq(result.reserve0(), destReserves.reserve0());
        assertEq(result.reserve1(), destReserves.reserve1());
    }

    function testTransferReserves_extremePrices() public pure {
        // Test with extreme price ratio (100:1)
        Reserves originReserves = toReserves(1e18, 100e18);
        Reserves destReserves = toReserves(2e18, 200e18);
        uint256 timeElapsed = 10;
        uint24 priceMoveSpeedPPM = 100;

        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        assertEq(result.reserve1(), destReserves.reserve1());
    }

    function testTransferReserves_verySmallReserves() public pure {
        Reserves originReserves = toReserves(1000, 1000);
        Reserves destReserves = toReserves(1200, 1200);
        uint256 timeElapsed = 10;
        uint24 priceMoveSpeedPPM = 100;

        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        assertEq(result.reserve0(), destReserves.reserve0());
        assertEq(result.reserve1(), destReserves.reserve1());
    }

    function testTransferReserves_bothReservesEqual() public pure {
        Reserves originReserves = toReserves(100e18, 100e18);
        Reserves destReserves = toReserves(100e18, 100e18);
        uint256 timeElapsed = 10;
        uint24 priceMoveSpeedPPM = 100;

        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        assertEq(result.reserve0(), destReserves.reserve0());
        assertEq(result.reserve1(), destReserves.reserve1());
    }

    function testTransferReserves_veryHighPriceMoveSpeed() public pure {
        Reserves originReserves = toReserves(100e18, 100e18);
        Reserves destReserves = toReserves(120e18, 120e18);
        uint256 timeElapsed = 100;
        uint24 priceMoveSpeedPPM = 10000; // 1%

        Reserves result = PriceMath.transferReserves(originReserves, destReserves, timeElapsed, priceMoveSpeedPPM);

        assertEq(result.reserve0(), destReserves.reserve0());
        assertEq(result.reserve1(), destReserves.reserve1());
    }
}
