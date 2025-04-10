// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolStatus} from "./PoolStatus.sol";
import {LendingStatus} from "./LendingStatus.sol";

/// @notice Returns the status of global.
struct GlobalStatus {
    /// @notice The status of pair pool.
    PoolStatus pairPoolStatus;
    /// @notice The status of lending pool.
    LendingStatus lendingStatus;
}
