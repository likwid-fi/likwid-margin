// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "../types/PoolKey.sol";

/// @title IMarginPositionReceiver
/// @notice A contract that accepts margin positions transferred into its namespace by a
/// third party via IMarginCore.transferPosition. Contracts that do not implement this (and
/// return the magic value) cannot have positions pushed into their namespace, which prevents
/// an attacker from pre-seeding a hostile position under a victim contract's predictable slot.
interface IMarginPositionReceiver {
    /// @notice Called by the margin core when a position is transferred into this contract's
    /// namespace by `from`. Must return this function's selector to accept the transfer.
    /// @param key The pool key of the position
    /// @param salt The position salt under this contract's ownership
    /// @param from The account that initiated the transfer
    function onMarginPositionReceived(PoolKey calldata key, bytes32 salt, address from)
        external
        returns (bytes4);
}
