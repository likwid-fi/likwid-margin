// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct RateStatus {
    uint24 rateBase;
    uint24 useMiddleLevel;
    uint24 useHighLevel;
    uint24 mLow;
    uint24 mMiddle;
    uint24 mHigh;
}
