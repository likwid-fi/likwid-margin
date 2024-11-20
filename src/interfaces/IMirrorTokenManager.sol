// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC6909Claims} from "v4-core/interfaces/external/IERC6909Claims.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface IMirrorTokenManager is IERC6909Claims {
    function getTokenId(PoolId poolId, Currency currency) external returns (uint256 _tokenId);

    function mint(uint256 id, uint256 amount) external;

    function burn(uint256 id, uint256 amount) external;

    function burnScale(uint256 id, uint256 total, uint256 amount) external;
}
