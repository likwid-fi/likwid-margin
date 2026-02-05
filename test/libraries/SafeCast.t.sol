// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "../../src/libraries/SafeCast.sol";

// Wrapper contract to test reverts from library
contract SafeCastWrapper {
    function toUint160(uint256 x) external pure returns (uint160) {
        return SafeCast.toUint160(x);
    }

    function toUint128(uint256 x) external pure returns (uint128) {
        return SafeCast.toUint128(x);
    }

    function toUint128(int128 x) external pure returns (uint128) {
        return SafeCast.toUint128(x);
    }

    function toInt128(int256 x) external pure returns (int128) {
        return SafeCast.toInt128(x);
    }

    function toInt256(uint256 x) external pure returns (int256) {
        return SafeCast.toInt256(x);
    }

    function toInt128(uint256 x) external pure returns (int128) {
        return SafeCast.toInt128(x);
    }

    function toInt128FromUint256(uint256 x) external pure returns (int128) {
        return SafeCast.toInt128(x);
    }
}

contract SafeCastTest is Test {
    SafeCastWrapper wrapper;

    function setUp() public {
        wrapper = new SafeCastWrapper();
    }

    function testToUintTrue() public pure {
        uint256 result = SafeCast.toUint(true);
        assertEq(result, 1, "true should cast to 1");
    }

    function testToUintFalse() public pure {
        uint256 result = SafeCast.toUint(false);
        assertEq(result, 0, "false should cast to 0");
    }

    function testToUint160() public pure {
        uint256 x = type(uint160).max;
        uint160 result = SafeCast.toUint160(x);
        assertEq(result, x, "Should cast max uint160 correctly");
    }

    function testToUint160Overflow() public {
        uint256 x = uint256(type(uint160).max) + 1;
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        wrapper.toUint160(x);
    }

    function testToUint128FromUint256() public pure {
        uint256 x = type(uint128).max;
        uint128 result = SafeCast.toUint128(x);
        assertEq(result, x, "Should cast max uint128 correctly");
    }

    function testToUint128FromUint256Overflow() public {
        uint256 x = uint256(type(uint128).max) + 1;
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        wrapper.toUint128(x);
    }

    function testToUint128FromInt128() public pure {
        int128 x = 100;
        uint128 result = SafeCast.toUint128(x);
        assertEq(result, 100, "Should cast positive int128 correctly");
    }

    function testToUint128FromNegativeInt128() public {
        int128 x = -1;
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        wrapper.toUint128(x);
    }

    function testToInt128FromInt256() public pure {
        int256 x = type(int128).max;
        int128 result = SafeCast.toInt128(x);
        assertEq(result, x, "Should cast max int128 correctly");
    }

    function testToInt128FromInt256Overflow() public {
        int256 x = int256(type(int128).max) + 1;
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        wrapper.toInt128(x);
    }

    function testToInt256FromUint256() public pure {
        uint256 x = uint256(int256(type(int256).max));
        int256 result = SafeCast.toInt256(x);
        assertEq(result, int256(x), "Should cast max safe uint256 correctly");
    }

    function testToInt256FromUint256Overflow() public {
        uint256 x = uint256(int256(type(int256).max)) + 1;
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        wrapper.toInt256(x);
    }

    function testToInt128FromUint256() public pure {
        uint256 x = uint256(uint128(type(int128).max));
        int128 result = SafeCast.toInt128(x);
        assertEq(result, int128(uint128(x)), "Should cast valid uint256 to int128 correctly");
    }

    function testToInt128FromUint256Overflow() public {
        uint256 x = uint256(uint128(type(int128).max)) + 1;
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        wrapper.toInt128FromUint256(x);
    }

    function testToUint160Zero() public pure {
        uint160 result = SafeCast.toUint160(0);
        assertEq(result, 0, "Should cast 0 correctly");
    }

    function testToUint128FromUint256Zero() public pure {
        uint128 result = SafeCast.toUint128(uint256(0));
        assertEq(result, 0, "Should cast 0 correctly");
    }

    function testToInt128FromInt256Zero() public pure {
        int128 result = SafeCast.toInt128(int256(0));
        assertEq(result, 0, "Should cast 0 correctly");
    }

    function testToInt256FromUint256Zero() public pure {
        int256 result = SafeCast.toInt256(0);
        assertEq(result, 0, "Should cast 0 correctly");
    }

    function testToInt128MinValue() public pure {
        int256 x = int256(type(int128).min);
        int128 result = SafeCast.toInt128(x);
        assertEq(result, type(int128).min, "Should cast min int128 correctly");
    }

    function testToInt128MinValueUnderflow() public {
        int256 x = int256(type(int128).min) - 1;
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        wrapper.toInt128(x);
    }

    function testToUint128FromInt128Zero() public pure {
        uint128 result = SafeCast.toUint128(int128(0));
        assertEq(result, 0, "Should cast int128 0 correctly");
    }

    function testToUint128FromInt128Max() public pure {
        int128 x = type(int128).max;
        uint128 result = SafeCast.toUint128(x);
        assertEq(result, uint128(type(int128).max), "Should cast int128 max correctly");
    }

    function testBooleanBoundary() public pure {
        assertEq(SafeCast.toUint(false), 0);
        assertEq(SafeCast.toUint(true), 1);
    }

    function testUint160Boundary() public pure {
        uint160 maxUint160 = type(uint160).max;
        assertEq(SafeCast.toUint160(maxUint160), maxUint160);
    }

    function testUint128Boundary() public pure {
        uint128 maxUint128 = type(uint128).max;
        assertEq(SafeCast.toUint128(maxUint128), maxUint128);
    }

    function testInt128Boundary() public pure {
        int128 maxInt128 = type(int128).max;
        int128 minInt128 = type(int128).min;

        assertEq(SafeCast.toInt128(int256(maxInt128)), maxInt128);
        assertEq(SafeCast.toInt128(int256(minInt128)), minInt128);
    }

    function testInt256Boundary() public pure {
        uint256 maxSafeUint = uint256(int256(type(int256).max));
        assertEq(SafeCast.toInt256(maxSafeUint), int256(maxSafeUint));
    }

    function testInt128FromUint256Boundary() public pure {
        uint256 maxSafe = uint256(uint128(type(int128).max));
        assertEq(SafeCast.toInt128(maxSafe), type(int128).max);
    }
}
