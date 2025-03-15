// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

/// @notice MarginParams is a struct that contains all the parameters needed to open a margin position.
struct MarginParams {
    /// @notice The poolId of the pool.
    PoolId poolId;
    /// @notice true: currency1 is marginToken, false: currency0 is marginToken
    bool marginForOne;
    /// @notice Leverage factor of the margin position.
    uint24 leverage;
    /// @notice The amount of margin
    uint256 marginAmount;
    /// @notice The borrow amount of the margin position.When the parameter is passed in, it is 0.
    uint256 borrowAmount;
    /// @notice The maximum borrow amount of the margin position.
    uint256 borrowMaxAmount;
    /// @notice Margin position recipient.
    address recipient;
    /// @notice Deadline for the transaction
    uint256 deadline;
}

struct MarginParamsVo {
    MarginParams params;
    /// @notice The total amount of margin,equals to marginAmount * leverage * (1-marginFee).
    uint256 marginTotal;
    /// @notice Min margin level.
    uint24 minMarginLevel;
    /// @notice Min margin level.
    Currency marginCurrency;
}
