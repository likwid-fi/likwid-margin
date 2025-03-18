// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct InterestStatus {
    uint256 allInterest;
    uint256 swapInterest;
    uint256 lendingInterest;
    uint256 lendingRealInterest;
    uint256 lendingMirrorInterest;
}
