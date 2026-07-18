// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IWETH9
/// @notice Minimal wrapped-native-token interface
interface IWETH9 {
    function deposit() external payable;

    function withdraw(uint256 amount) external;
}
