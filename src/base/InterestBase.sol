// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IInterestBase} from "../interfaces/IInterestBase.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {RateState} from "../types/RateState.sol";

abstract contract InterestBase is IInterestBase, Owned {
    RateState public rateState;

    constructor(address initialOwner) Owned(initialOwner) {}

    /// @inheritdoc IInterestBase
    function setRateState(RateState newRateState) external onlyOwner {
        rateState = newRateState;
        emit RateStateUpdated(newRateState);
    }
}
