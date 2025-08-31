// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PositionLibrary} from "../../src/libraries/PositionLibrary.sol";

contract PositionLibraryTest is Test {
    using PositionLibrary for address;

    function testCalculatePositionKey() public pure {
        address owner = address(0x123);
        bytes32 salt = keccak256("testSalt01");
        bytes32 positionKey = owner.calculatePositionKey(salt);
        bytes32 expectedKey = keccak256(abi.encodePacked(owner, salt));
        assertEq(positionKey, expectedKey, "Position key should match expected hash");
        salt = keccak256("testSalt02");
        positionKey = owner.calculatePositionKey(salt);
        expectedKey = keccak256(abi.encodePacked(owner, salt));
        assertEq(positionKey, expectedKey, "Position key should match expected hash");
    }

    function testCalculatePositionKeyWithIsOne() public pure {
        address owner = address(0x123);
        bytes32 salt = keccak256("testSalt");
        bytes32 positionKey = PositionLibrary.calculatePositionKey(owner, false, salt);
        bytes32 expectedKey = keccak256(abi.encodePacked(owner, false, salt));
        assertEq(positionKey, expectedKey, "Position key with false should match expected hash");
        positionKey = PositionLibrary.calculatePositionKey(owner, true, salt);
        expectedKey = keccak256(abi.encodePacked(owner, true, salt));
        assertEq(positionKey, expectedKey, "Position key with true should match expected hash");
    }
}
