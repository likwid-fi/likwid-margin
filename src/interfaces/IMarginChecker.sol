// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IMarginChecker {
    function checkLiquidate(address sender, uint256 positionId, bytes calldata signature)
        external
        view
        returns (bool);
}
