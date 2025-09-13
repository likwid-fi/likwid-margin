// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "../types/PoolId.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {MarginLevels} from "../types/MarginLevels.sol";
import {IImmutableState} from "./IImmutableState.sol";

interface IBasePositionManager is IImmutableState {
    function poolIds(uint256 tokenId) external view returns (PoolId poolId);
}
