// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

struct MarginPosition {
    PoolId poolId;
    bool marginForOne; // true: currency1 is marginToken, false: currency0 is marginToken
    // marginAmount1 + ... + marginAmountN
    uint128 marginAmount;
    // marginTotal1 + ... + marginTotalN
    uint128 marginTotal;
    uint128 borrowAmount;
    uint128 rawBorrowAmount;
    uint256 rateCumulativeLast;
}

struct MarginPositionVo {
    MarginPosition position;
    int256 pnl;
}

struct BurnParams {
    PoolId poolId;
    bool marginForOne; // true: currency1 is marginToken, false: currency0 is marginToken
    uint256[] positionIds;
    bytes signature;
}
