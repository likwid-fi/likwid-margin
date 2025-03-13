// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolStatus} from "../types/PoolStatus.sol";

interface IPoolBase {
    function getStatus(PoolId poolId) external view returns (PoolStatus memory _status);
}
