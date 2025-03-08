// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test, console} from "forge-std/Test.sol";
import {PoolStatus} from "../src/types/PoolStatus.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract CommonStructTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => PoolStatus) public hookStatusStore;
    mapping(uint256 => PoolStatus) public hookStatusStore1;
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
            positions[i].rateCumulativeLast = i + 10000;
        }
    }

    function test_create() public {
        PoolStatus memory status;
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

    function test_shift_01() public pure {
        uint112 test = type(uint112).max;
        uint24 test24 = uint24(test);
        uint256 test1 = uint256(test) << 96;
        assertEq(test1 / test, 2 ** 96);
        console.log("test:%s,test1:%s,test24:%s", test, test1, test24);
    }

    function test_shift_02() public pure {
        uint112 test = 1;
        uint256 test1 = uint256(test) << 96;
        uint24 test24 = uint24(test1);
        assertEq(test1 / test, 2 ** 96);
        console.log("test:%s,test1:%s,test24:%s", test, test1, test24);
    }

    function test_shift_03() public pure {
        uint128 reserve0 = 11223344;
        uint128 reserve1 = 22443355;
        uint256 reserves = (uint256(reserve0) << 128) + uint256(reserve1);
        uint256 half = reserves >> 1;
        uint128 half0 = uint128(half >> 128);
        uint128 half1 = uint128(half);
        assertEq(half0, reserve0 / 2);
        assertEq(half1, reserve1 / 2);
        uint128 _reserve0 = 1122334422;
        uint128 _reserve1 = 2244335544;
        uint256 _reserves = (uint256(_reserve0) << 128) + uint256(_reserve1);
        uint256 _half = (reserves + _reserves) >> 1;
        uint128 _half0 = uint128(_half >> 128);
        uint128 _half1 = uint128(_half);
        assertEq(_half0, (reserve0 + _reserve0) / 2);
        assertEq(_half1, (reserve1 + _reserve1) / 2);
    }

    function testBurnPosition() public {
        uint256 positionId = 10;
        assertGt(positions[positionId].rateCumulativeLast, 0);
        delete positions[positionId];
        assertEq(positions[positionId].rateCumulativeLast, 0);
    }

    function changeKey(PoolKey memory tempKey) internal pure {
        tempKey.fee = 100;
    }

    function testChangeKey() public pure {
        PoolKey memory tempKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
        assertEq(tempKey.fee, 0);
        changeKey(tempKey);
        assertEq(tempKey.fee, 100);
    }

    function testMulDiv() public pure {
        uint256 a = 1111111111111111;
        uint256 n = 9111;
        uint256 d = 7777;
        uint256 t1 = a * n / d;
        uint256 t2 = Math.mulDiv(a, n, d);
        assertEq(t1, t2);
    }

    struct SmallStruct {
        uint256 reserve;
    }

    struct BigStruct {
        uint256 reserve0;
        uint256 reserve1;
        uint256 reserve2;
        uint256 reserve3;
        uint256 reserve4;
        uint256 reserve5;
        uint256 reserve6;
        uint256 reserve7;
        uint256 reserve8;
        uint256 reserve9;
    }

    mapping(uint256 => SmallStruct) smallStructMap;
    mapping(uint256 => BigStruct) bigStructMap;

    function createSmallStruct() public {
        for (uint256 i = 0; i < 100; i++) {
            SmallStruct memory small;
            small.reserve = i;
            smallStructMap[i] = small;
        }
    }

    function createBigStruct() public {
        for (uint256 i = 0; i < 100; i++) {
            BigStruct memory big;
            big.reserve0 = i;
            bigStructMap[i] = big;
        }
    }

    function testCreateStructsBig() public {
        createBigStruct();
    }

    function testCreateStructsSmall() public {
        createSmallStruct();
    }
}
