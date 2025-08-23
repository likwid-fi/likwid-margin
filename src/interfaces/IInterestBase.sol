// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {RateState} from "../types/RateState.sol";

/// @notice Interface for all interest-fee related functions in the pool manager
interface IInterestBase {
    /// @notice Emitted when the rate state is updated
    /// @param newRateState The new rate state being set
    /// @dev This event is emitted when the rate state is updated, allowing external observers to
    event RateStateUpdated(RateState indexed newRateState);

    /// @notice Sets the rate state for interest fees
    /// @param newRateState The new rate state to set
    /// @dev This function allows the owner to update the rate state, which is used to
    /// calculate interest fees. It emits a RateStateUpdated event upon success.
    /// @dev Only the owner can call this function.
    /// @dev Reverts if the caller is not the owner.
    function setRateState(RateState newRateState) external;
}
