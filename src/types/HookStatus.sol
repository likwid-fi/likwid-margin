// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";

struct HookStatus {
    Currency currency0;
    Currency currency1;
    uint256 reserve0;
    uint256 reserve1;
    uint256 mirrorReserve0;
    uint256 mirrorReserve1;
    uint256 blockTimestampLast; // uses single storage slot, accessible via getReserves
    uint256 rate0CumulativeLast;
    uint256 rate1CumulativeLast;
    uint24 initialLTV; // 50%
    uint24 liquidationLTV; // 90%
    uint24 fee; // 3000 = 0.3%
    uint24 marginFee; // 15000 = 1.5%
    uint24 protocolFee; // 0.3%
    uint24 protocolMarginFee; // 0.5%
}
