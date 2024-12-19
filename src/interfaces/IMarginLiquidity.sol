// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC6909Claims} from "v4-core/interfaces/external/IERC6909Claims.sol";

interface IMarginLiquidity is IERC6909Claims {
    function mint(address receiver, uint256 id, uint256 amount) external;

    function burn(address sender, uint256 id, uint256 amount) external;

    function addLiquidity(address receiver, uint256 id, uint8 level, uint256 amount) external;

    function removeLiquidity(address sender, uint256 id, uint8 level, uint256 amount) external;
}
