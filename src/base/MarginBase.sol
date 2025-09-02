// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMarginBase} from "../interfaces/IMarginBase.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {MarginState} from "../types/MarginState.sol";

abstract contract MarginBase is IMarginBase, Owned {
    MarginState public marginState;

    constructor(address initialOwner) Owned(initialOwner) {}

    /// @inheritdoc IMarginBase
    function setMarginState(MarginState newMarginState) external onlyOwner {
        marginState = newMarginState;
        emit MarginStateUpdated(newMarginState);
    }
}
