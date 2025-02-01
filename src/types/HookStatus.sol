// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

struct HookStatus {
    uint112 realReserve0;
    uint112 realReserve1;
    uint112 mirrorReserve0;
    uint112 mirrorReserve1;
    uint24 marginFee; // 15000 = 1.5%
    uint32 blockTimestampLast;
    uint112 interestRatio0X112;
    uint112 interestRatio1X112;
    uint256 rate0CumulativeLast;
    uint256 rate1CumulativeLast;
    uint32 marginTimestampLast;
    uint224 lastPrice1X112;
    PoolKey key;
}

struct BalanceStatus {
    uint256 balance0;
    uint256 balance1;
    uint256 mirrorBalance0;
    uint256 mirrorBalance1;
}
