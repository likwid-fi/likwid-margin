// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

struct HookStatus {
    uint112 realReserve0;
    uint112 realReserve1;
    uint112 mirrorReserve0;
    uint112 mirrorReserve1;
    uint32 blockTimestampLast;
    uint256 rate0CumulativeLast;
    uint256 rate1CumulativeLast;
    PoolKey key;
    FeeStatus feeStatus;
}

struct FeeStatus {
    uint24 initialLTV; // 50%
    uint24 liquidationLTV; // 90%
    uint24 marginFee; // 15000 = 1.5%
    uint32 lastMarginTimestamp;
    uint224 lastPrice1X112;
}

struct BalanceStatus {
    uint256 balance0;
    uint256 balance1;
    uint256 mirrorBalance0;
    uint256 mirrorBalance1;
}
