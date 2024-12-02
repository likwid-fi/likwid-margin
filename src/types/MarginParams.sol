// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

struct MarginParams {
    PoolId poolId;
    bool marginForOne; // true: currency1 is marginToken, false: currency0 is marginToken
    uint24 leverage;
    uint256 marginAmount;
    uint256 marginTotal;
    uint256 borrowAmount;
    uint256 borrowMinAmount;
    address recipient;
    uint256 deadline;
}

struct RepayParams {
    PoolId poolId;
    bool marginForOne; // true: currency1 is marginToken, false: currency0 is marginToken
    address payer;
    uint256 repayAmount;
    uint256 releaseAmount;
    uint256 borrowAmount;
    uint256 deadline;
}

struct LiquidateParams {
    PoolId poolId;
    bool marginForOne; // true: currency1 is marginToken, false: currency0 is marginToken
    uint256 repayAmount;
    uint256 borrowAmount;
    uint256 releaseAmount;
}
