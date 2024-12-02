// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MarginPosition} from "../types/MarginPosition.sol";

interface IMarginPositionManager is IERC721 {
    function getHook() external view returns (address _hook);
    function getPosition(uint256 positionId) external view returns (MarginPosition memory _position);
}
