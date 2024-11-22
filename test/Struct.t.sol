// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {HookStatus} from "../src/types/HookStatus.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract StructTest is Test {
    using CurrencyLibrary for Currency;

    mapping(PoolId => HookStatus) public hookStatusStore;
    PoolKey public key;

    function setUp() public {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
    }

    function test_create() public {
        HookStatus memory status;
        status.currency0 = key.currency0;
        hookStatusStore[key.toId()] = status;
    }

    function test_get() public {
        test_create();
        // hookStatusStore[key.toId()].currency0 == key.currency0;
        Currency.wrap(address(0)) == Currency.wrap(address(1));
        // assertTrue(hookStatusStore[key.toId()].currency0 == key.currency0);
    }
}
