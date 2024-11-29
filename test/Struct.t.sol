// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {HookStatus} from "../src/types/HookStatus.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract StructTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => HookStatus) public hookStatusStore;
    mapping(uint256 => HookStatus) public hookStatusStore1;
    mapping(uint256 => MarginPosition) public positions;
    mapping(uint256 => uint256) public testMap;
    PoolKey public key;

    function setUp() public {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
        for (uint256 i = 0; i < 100; i++) {
            positions[i].rateCumulativeLast = i;
        }
    }

    function test_create() public {
        HookStatus memory status;
        status.key = key;
        hookStatusStore[key.toId()] = status;
    }

    function test_get() public {
        test_create();
        // hookStatusStore[key.toId()].currency0 == key.currency0;
        Currency.wrap(address(0)) == Currency.wrap(address(1));
        // assertTrue(hookStatusStore[key.toId()].currency0 == key.currency0);
    }

    function toHexString(bytes32 data) public pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory str = new bytes(64);

        for (uint256 i = 0; i < 32; i++) {
            uint8 byteValue = uint8(data[i]);
            str[i * 2] = hexChars[byteValue >> 4];
            str[i * 2 + 1] = hexChars[byteValue & 0x0f];
        }

        return string(str);
    }

    function test_uint32() public view {
        uint32 timestamp = uint32((2 ** 32 + 1) % 2 ** 32);
        console.log("timestamp:%s,poolId:%s", timestamp, toHexString(PoolId.unwrap(key.toId())));
    }

    function test_set_status() public {}

    function test_update_status() public {
        test_set_status();
        for (uint256 i = 0; i < 100; i++) {
            positions[i].rateCumulativeLast = i + 10;
        }
        // for (uint256 i = 0; i < 100; i++) {
        //     uint256 test = testMap[i];
        //     test == 0;
        // }
    }
}
