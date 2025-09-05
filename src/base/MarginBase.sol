// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMarginBase} from "../interfaces/IMarginBase.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {MarginState} from "../types/MarginState.sol";

abstract contract MarginBase is IMarginBase, Owned {
    MarginState public marginState;

    uint24 private constant MAX_PRICE_MOVE_PER_SECOND = 3000; // 0.3%/second
    uint24 private constant RATE_BASE = 50000;
    uint24 private constant USE_MIDDLE_LEVEL = 400000;
    uint24 private constant USE_HIGH_LEVEL = 800000;
    uint24 private constant M_LOW = 10;
    uint24 private constant M_MIDDLE = 100;
    uint24 private constant M_HIGH = 10000;
    uint24 private constant STAGE_DURATION = 1 hours; // default: 1 hour seconds
    uint24 private constant STAGE_SIZE = 5; // default: 5 stages
    uint24 private constant STAGE_LEAVE_PART = 5; // default: 5, meaning 20% of the total liquidity is free

    constructor(address initialOwner) Owned(initialOwner) {
        MarginState _marginState = marginState.setMaxPriceMovePerSecond(MAX_PRICE_MOVE_PER_SECOND);
        _marginState = _marginState.setRateBase(RATE_BASE);
        _marginState = _marginState.setUseMiddleLevel(USE_MIDDLE_LEVEL);
        _marginState = _marginState.setUseHighLevel(USE_HIGH_LEVEL);
        _marginState = _marginState.setMLow(M_LOW);
        _marginState = _marginState.setMMiddle(M_MIDDLE);
        _marginState = _marginState.setMHigh(M_HIGH);
        _marginState = _marginState.setStageDuration(STAGE_DURATION);
        _marginState = _marginState.setStageSize(STAGE_SIZE);
        _marginState = _marginState.setStageLeavePart(STAGE_LEAVE_PART);
        marginState = _marginState;
    }

    /// @inheritdoc IMarginBase
    function setMarginState(MarginState newMarginState) external onlyOwner {
        marginState = newMarginState;
        emit MarginStateUpdated(newMarginState);
    }
}
