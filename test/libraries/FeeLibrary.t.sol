// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeLibrary} from "../../src/libraries/FeeLibrary.sol";
import {PerLibrary} from "../../src/libraries/PerLibrary.sol";

contract FeeLibraryTest is Test {
    using FeeLibrary for uint24;

    uint24 constant FEE_1_PERCENT = 10000; // 1%
    uint24 constant FEE_0_3_PERCENT = 3000; // 0.3%
    uint24 constant FEE_10_PERCENT = 100000; // 10%

    function testDeductFrom() public pure {
        uint256 amount = 1000 ether;
        uint256 amountWithoutFee = FEE_1_PERCENT.deductFrom(amount);

        // 1% fee means 99% remains
        uint256 expected = (amount * (PerLibrary.ONE_MILLION - FEE_1_PERCENT)) / PerLibrary.ONE_MILLION;
        assertEq(amountWithoutFee, expected, "Should deduct 1% fee");
    }

    function testDeduct() public pure {
        uint256 amount = 1000 ether;
        (uint256 amountWithoutFee, uint256 feeAmount) = FEE_1_PERCENT.deduct(amount);

        assertEq(amountWithoutFee + feeAmount, amount, "Amounts should sum to original");
        assertApproxEqRel(feeAmount, 10 ether, 0.0001e18, "Fee should be approximately 10 ether (1%)");
    }

    function testAttachFrom() public pure {
        uint256 amount = 990 ether;
        uint256 amountWithFee = FEE_1_PERCENT.attachFrom(amount);

        // To get 990 after 1% fee, we need 990 / 0.99 = 1000
        uint256 expected = (amount * PerLibrary.ONE_MILLION) / (PerLibrary.ONE_MILLION - FEE_1_PERCENT);
        assertEq(amountWithFee, expected, "Should calculate amount with fee attached");
    }

    function testAttach() public pure {
        uint256 amount = 990 ether;
        (uint256 amountWithFee, uint256 feeAmount) = FEE_1_PERCENT.attach(amount);

        assertEq(amountWithFee - feeAmount, amount, "Amount with fee minus fee should equal original");
    }

    function testPart() public pure {
        uint256 amount = 1000 ether;
        uint256 feeAmount = FEE_1_PERCENT.part(amount);

        uint256 expected = (amount * FEE_1_PERCENT) / PerLibrary.ONE_MILLION;
        assertEq(feeAmount, expected, "Should calculate fee part");
        assertEq(feeAmount, 10 ether, "Fee should be 10 ether");
    }

    function testBound() public pure {
        uint256 amount = 1000 ether;
        (uint256 lower, uint256 upper) = FEE_1_PERCENT.bound(amount);

        // Lower is amount after deducting fee
        // Upper is amount with fee attached
        assertLt(lower, amount, "Lower bound should be less than amount");
        assertGt(upper, amount, "Upper bound should be greater than amount");

        // Verify relationship
        assertEq(lower, FEE_1_PERCENT.deductFrom(amount), "Lower should be deductFrom result");
        assertEq(upper, FEE_1_PERCENT.attachFrom(amount), "Upper should be attachFrom result");
    }

    function testDeductFromZeroFee() public pure {
        uint256 amount = 1000 ether;
        uint24 zeroFee = 0;
        uint256 result = zeroFee.deductFrom(amount);

        assertEq(result, amount, "Zero fee should return same amount");
    }

    function testDeductFromMaxFee() public pure {
        uint256 amount = 1000 ether;
        uint24 maxFee = 999999; // Just under 100%
        uint256 result = maxFee.deductFrom(amount);

        assertLt(result, amount, "Max fee should reduce amount");
        assertGt(result, 0, "Should still have some amount remaining");
    }

    function testAttachFromZeroFee() public pure {
        uint256 amount = 1000 ether;
        uint24 zeroFee = 0;
        uint256 result = zeroFee.attachFrom(amount);

        assertEq(result, amount, "Zero fee should return same amount");
    }

    function testPartZeroFee() public pure {
        uint256 amount = 1000 ether;
        uint24 zeroFee = 0;
        uint256 result = zeroFee.part(amount);

        assertEq(result, 0, "Zero fee should return 0");
    }

    function testPartMaxFee() public pure {
        uint256 amount = 1000 ether;
        uint24 maxFee = 1000000; // 100%
        uint256 result = maxFee.part(amount);

        assertEq(result, amount, "100% fee should return full amount");
    }

    function testDeductRoundTrip() public pure {
        uint256 originalAmount = 1000 ether;

        // Deduct fee
        (uint256 withoutFee, uint256 fee) = FEE_1_PERCENT.deduct(originalAmount);

        // Attach fee back
        (uint256 withFee,) = FEE_1_PERCENT.attach(withoutFee);

        // Should be close to original (may have rounding differences)
        assertApproxEqRel(withFee, originalAmount, 0.0001e18, "Round trip should approximate original");
    }

    function testAttachRoundTrip() public pure {
        uint256 originalAmount = 990 ether;

        // Attach fee
        (uint256 withFee, uint256 fee) = FEE_1_PERCENT.attach(originalAmount);

        // Deduct fee
        (uint256 withoutFee,) = FEE_1_PERCENT.deduct(withFee);

        // Should be close to original (may have rounding differences)
        assertApproxEqRel(withoutFee, originalAmount, 0.0001e18, "Round trip should approximate original");
    }

    function testBoundSymmetry() public pure {
        uint256 amount = 1000 ether;
        (uint256 lower, uint256 upper) = FEE_1_PERCENT.bound(amount);

        // Lower bound should be less than amount, upper should be greater
        assertLt(lower, amount, "Lower should be less than amount");
        assertGt(upper, amount, "Upper should be greater than amount");

        // The differences should be approximately equal
        uint256 lowerDiff = amount - lower;
        uint256 upperDiff = upper - amount;

        // These should be approximately equal (accounting for rounding)
        assertApproxEqRel(lowerDiff, upperDiff, 0.01e18, "Differences should be approximately equal");
    }

    function testMultipleFees() public pure {
        uint256 amount = 10000 ether;

        // Test different fee levels
        uint24[] memory fees = new uint24[](5);
        fees[0] = 100;    // 0.01%
        fees[1] = 1000;   // 0.1%
        fees[2] = 3000;   // 0.3%
        fees[3] = 10000;  // 1%
        fees[4] = 50000;  // 5%

        for (uint i = 0; i < fees.length; i++) {
            uint24 fee = fees[i];
            uint256 feeAmount = fee.part(amount);
            uint256 expected = (amount * fee) / PerLibrary.ONE_MILLION;
            assertEq(feeAmount, expected, "Fee calculation should be correct");
        }
    }

    function testSmallAmounts() public pure {
        uint256 smallAmount = 100; // Very small amount
        uint24 fee = FEE_1_PERCENT;

        uint256 result = fee.deductFrom(smallAmount);
        assertLe(result, smallAmount, "Result should be less or equal");
        assertGe(result, 0, "Result should be non-negative");
    }

    function testLargeAmounts() public pure {
        uint256 largeAmount = type(uint128).max;
        uint24 fee = FEE_0_3_PERCENT;

        uint256 result = fee.deductFrom(largeAmount);
        assertLt(result, largeAmount, "Result should be less than large amount");
        assertGt(result, 0, "Result should be positive");
    }
}
