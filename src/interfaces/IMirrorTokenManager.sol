// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC6909Claims} from "v4-core/interfaces/external/IERC6909Claims.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

interface IMirrorTokenManager is IERC6909Claims {
    function mint(uint256 id, uint256 amount) external;

    function burn(uint256 id, uint256 amount) external;

    function burnScale(uint256 id, uint256 total, uint256 amount) external;
}
