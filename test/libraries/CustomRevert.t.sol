// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CustomRevert} from "../../src/libraries/CustomRevert.sol";

contract CustomRevertTest is Test {
    using CustomRevert for bytes4;

    // Custom errors for testing
    error SimpleError();
    error ErrorWithAddress(address addr);
    error ErrorWithInt24(int24 value);
    error ErrorWithUint160(uint160 value);
    error ErrorWithTwoInt24(int24 value1, int24 value2);
    error ErrorWithTwoUint160(uint160 value1, uint160 value2);
    error ErrorWithTwoAddress(address value1, address value2);

    function testRevertWithSimple() public {
        vm.expectRevert(SimpleError.selector);
        this.callRevertWithSimple();
    }

    function callRevertWithSimple() external pure {
        SimpleError.selector.revertWith();
    }

    function testRevertWithAddress() public {
        address testAddr = address(0x123);
        vm.expectRevert(abi.encodeWithSelector(ErrorWithAddress.selector, testAddr));
        this.callRevertWithAddress(testAddr);
    }

    function callRevertWithAddress(address addr) external pure {
        ErrorWithAddress.selector.revertWith(addr);
    }

    function testRevertWithInt24() public {
        int24 testValue = -1000;
        vm.expectRevert(abi.encodeWithSelector(ErrorWithInt24.selector, testValue));
        this.callRevertWithInt24(testValue);
    }

    function callRevertWithInt24(int24 value) external pure {
        ErrorWithInt24.selector.revertWith(value);
    }

    function testRevertWithUint160() public {
        uint160 testValue = 12345;
        vm.expectRevert(abi.encodeWithSelector(ErrorWithUint160.selector, testValue));
        this.callRevertWithUint160(testValue);
    }

    function callRevertWithUint160(uint160 value) external pure {
        ErrorWithUint160.selector.revertWith(value);
    }

    function testRevertWithTwoInt24() public {
        int24 value1 = -1000;
        int24 value2 = 2000;
        vm.expectRevert(abi.encodeWithSelector(ErrorWithTwoInt24.selector, value1, value2));
        this.callRevertWithTwoInt24(value1, value2);
    }

    function callRevertWithTwoInt24(int24 value1, int24 value2) external pure {
        ErrorWithTwoInt24.selector.revertWith(value1, value2);
    }

    function testRevertWithTwoUint160() public {
        uint160 value1 = 12345;
        uint160 value2 = 67890;
        vm.expectRevert(abi.encodeWithSelector(ErrorWithTwoUint160.selector, value1, value2));
        this.callRevertWithTwoUint160(value1, value2);
    }

    function callRevertWithTwoUint160(uint160 value1, uint160 value2) external pure {
        ErrorWithTwoUint160.selector.revertWith(value1, value2);
    }

    function testRevertWithTwoAddress() public {
        address addr1 = address(0x123);
        address addr2 = address(0x456);
        vm.expectRevert(abi.encodeWithSelector(ErrorWithTwoAddress.selector, addr1, addr2));
        this.callRevertWithTwoAddress(addr1, addr2);
    }

    function callRevertWithTwoAddress(address addr1, address addr2) external pure {
        ErrorWithTwoAddress.selector.revertWith(addr1, addr2);
    }

    function testRevertWithAddressZero() public {
        address testAddr = address(0);
        vm.expectRevert(abi.encodeWithSelector(ErrorWithAddress.selector, testAddr));
        this.callRevertWithAddress(testAddr);
    }

    function testRevertWithAddressMax() public {
        address testAddr = address(type(uint160).max);
        vm.expectRevert(abi.encodeWithSelector(ErrorWithAddress.selector, testAddr));
        this.callRevertWithAddress(testAddr);
    }

    function testRevertWithInt24Max() public {
        int24 testValue = type(int24).max;
        vm.expectRevert(abi.encodeWithSelector(ErrorWithInt24.selector, testValue));
        this.callRevertWithInt24(testValue);
    }

    function testRevertWithInt24Min() public {
        int24 testValue = type(int24).min;
        vm.expectRevert(abi.encodeWithSelector(ErrorWithInt24.selector, testValue));
        this.callRevertWithInt24(testValue);
    }

    function testRevertWithUint160Max() public {
        uint160 testValue = type(uint160).max;
        vm.expectRevert(abi.encodeWithSelector(ErrorWithUint160.selector, testValue));
        this.callRevertWithUint160(testValue);
    }

    function testRevertWithUint160Zero() public {
        uint160 testValue = 0;
        vm.expectRevert(abi.encodeWithSelector(ErrorWithUint160.selector, testValue));
        this.callRevertWithUint160(testValue);
    }

    function testRevertWithTwoInt24Boundary() public {
        int24 value1 = type(int24).min;
        int24 value2 = type(int24).max;
        vm.expectRevert(abi.encodeWithSelector(ErrorWithTwoInt24.selector, value1, value2));
        this.callRevertWithTwoInt24(value1, value2);
    }

    function testRevertWithTwoUint160Boundary() public {
        uint160 value1 = 0;
        uint160 value2 = type(uint160).max;
        vm.expectRevert(abi.encodeWithSelector(ErrorWithTwoUint160.selector, value1, value2));
        this.callRevertWithTwoUint160(value1, value2);
    }

    function testRevertWithTwoAddressSame() public {
        address addr = address(0x123);
        vm.expectRevert(abi.encodeWithSelector(ErrorWithTwoAddress.selector, addr, addr));
        this.callRevertWithTwoAddress(addr, addr);
    }
}
