// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {MarginPosition} from "./types/MarginPosition.sol";

contract MarginPositionManager is ERC721 {
    mapping(uint256 => MarginPosition) private _positions;

    constructor() ERC721("LIKWIDMarginPositionManager", "LMPM") {}
}
