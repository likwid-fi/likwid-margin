// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC6909} from "./IERC6909.sol";

/// @notice Interface for accrues over a contract balance, wrapped as a ERC6909
interface IERC6909Accrues is IERC6909 {
    function accruesRatioX112Of(uint256 id) external view returns (uint256);

    function totalSupply(uint256 id) external view returns (uint256);
}
