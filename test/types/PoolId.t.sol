// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "src/types/PoolId.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract PoolIdTest is Test {
    using CurrencyLibrary for Currency;

    function testToId() public {
        MockERC20 token0 = new MockERC20("Token A", "TKA", 18);
        MockERC20 token1 = new MockERC20("Token B", "TKB", 18);

        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));

        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory poolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, marginFee: 1000});

        PoolId poolId = PoolIdLibrary.toId(poolKey);
        bytes32 expectedPoolId = keccak256(abi.encode(poolKey));
        assertEq(PoolId.unwrap(poolId), expectedPoolId);

        poolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, marginFee: 1200});
        PoolId poolIdChanged01 = PoolIdLibrary.toId(poolKey);
        assertNotEq(PoolId.unwrap(poolIdChanged01), expectedPoolId);

        poolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 3100, marginFee: 1000});
        PoolId poolIdChanged02 = PoolIdLibrary.toId(poolKey);
        bytes32 expectedPoolId02 = keccak256(abi.encode(poolKey));
        assertNotEq(PoolId.unwrap(poolIdChanged01), PoolId.unwrap(poolIdChanged02));
        assertEq(PoolId.unwrap(poolIdChanged02), expectedPoolId02);
    }
}
