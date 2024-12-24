// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Owned} from "solmate/src/auth/Owned.sol";
import {IMarginChecker} from "./interfaces/IMarginChecker.sol";

contract MarginChecker is IMarginChecker, Owned {
    constructor(address initialOwner) Owned(initialOwner) {}

    function checkLiquidate(address, uint256, bytes calldata) external pure returns (bool) {
        return true;
    }
}
