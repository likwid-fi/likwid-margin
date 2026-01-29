// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PositionLibrary} from "../../src/libraries/PositionLibrary.sol";

contract PositionLibraryTest is Test {
    using PositionLibrary for address;

    function testCalculatePositionKey01() public pure {
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

    function testCalculatePositionKey02() public pure {
        address owner = address(0x123);
        uint256 tokenId = 1;
        bytes32 salt = bytes32(tokenId);
        bytes32 positionKey01 = owner.calculatePositionKey(salt);
        bytes32 expectedKey01 = keccak256(abi.encodePacked(owner, salt));
        assertEq(positionKey01, expectedKey01, "Position key should match expected hash");
        tokenId = 2;
        salt = bytes32(tokenId);
        bytes32 positionKey02 = owner.calculatePositionKey(salt);
        bytes32 expectedKey02 = keccak256(abi.encodePacked(owner, salt));
        assertEq(positionKey02, expectedKey02, "Position key should match expected hash");
        assertNotEq(positionKey01, expectedKey02);
    }

    function testCalculatePositionKeyWithIsOne01() public pure {
        address owner = address(0x123);
        bytes32 salt = keccak256("testSalt");
        bytes32 positionKey01 = PositionLibrary.calculatePositionKey(owner, false, salt);
        bytes32 expectedKey01 = keccak256(abi.encodePacked(owner, false, salt));
        assertEq(positionKey01, expectedKey01, "Position key with false should match expected hash");
        bytes32 positionKey02 = PositionLibrary.calculatePositionKey(owner, true, salt);
        bytes32 expectedKey02 = keccak256(abi.encodePacked(owner, true, salt));
        assertEq(positionKey02, expectedKey02, "Position key with true should match expected hash");
        assertNotEq(positionKey01, expectedKey02);
    }

    function testCalculatePositionKeyWithIsOne02() public pure {
        address owner = address(0x123);
        uint256 tokenId = 1;
        bytes32 salt = bytes32(tokenId);
        bytes32 positionKey01 = PositionLibrary.calculatePositionKey(owner, false, salt);
        bytes32 expectedKey01 = keccak256(abi.encodePacked(owner, false, salt));
        assertEq(positionKey01, expectedKey01, "Position key with false should match expected hash");
        tokenId = 2;
        salt = bytes32(tokenId);
        bytes32 positionKey02 = PositionLibrary.calculatePositionKey(owner, true, salt);
        bytes32 expectedKey02 = keccak256(abi.encodePacked(owner, true, salt));
        assertEq(positionKey02, expectedKey02, "Position key with true should match expected hash");
        assertNotEq(positionKey01, expectedKey02);
    }

    function testCalculatePositionKey_differentOwners() public pure {
        address owner1 = address(0x123);
        address owner2 = address(0x456);
        bytes32 salt = keccak256("testSalt");

        bytes32 positionKey1 = owner1.calculatePositionKey(salt);
        bytes32 positionKey2 = owner2.calculatePositionKey(salt);

        assertNotEq(positionKey1, positionKey2, "Different owners should have different keys");
    }

    function testCalculatePositionKey_zeroAddress() public pure {
        address owner = address(0);
        bytes32 salt = keccak256("testSalt");

        bytes32 positionKey = owner.calculatePositionKey(salt);
        bytes32 expectedKey = keccak256(abi.encodePacked(owner, salt));

        assertEq(positionKey, expectedKey, "Zero address should work correctly");
    }

    function testCalculatePositionKeyWithIsOne_differentFlags() public pure {
        address owner = address(0x123);
        bytes32 salt = keccak256("testSalt");

        bytes32 keyFalse = PositionLibrary.calculatePositionKey(owner, false, salt);
        bytes32 keyTrue = PositionLibrary.calculatePositionKey(owner, true, salt);

        assertNotEq(keyFalse, keyTrue, "Different isForOne flags should produce different keys");
    }

    function testCalculatePositionKey_consistency() public pure {
        address owner = address(0x123);
        bytes32 salt = keccak256("testSalt");

        bytes32 key1 = owner.calculatePositionKey(salt);
        bytes32 key2 = owner.calculatePositionKey(salt);

        assertEq(key1, key2, "Same inputs should produce same key");
    }

    function testCalculatePositionKeyWithIsOne_consistency() public pure {
        address owner = address(0x123);
        bytes32 salt = keccak256("testSalt");

        bytes32 key1 = PositionLibrary.calculatePositionKey(owner, true, salt);
        bytes32 key2 = PositionLibrary.calculatePositionKey(owner, true, salt);

        assertEq(key1, key2, "Same inputs should produce same key");
    }

    function testCalculatePositionKey_uniqueSalts() public pure {
        address owner = address(0x123);
        bytes32 salt1 = keccak256("salt1");
        bytes32 salt2 = keccak256("salt2");

        bytes32 key1 = owner.calculatePositionKey(salt1);
        bytes32 key2 = owner.calculatePositionKey(salt2);

        assertNotEq(key1, key2, "Different salts should produce different keys");
    }
}
