// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {IPairPoolManager} from "./IPairPoolManager.sol";
import {PoolStatus} from "../types/PoolStatus.sol";

interface IMarginOracleReader {
    function observeNow(IPairPoolManager poolManager, PoolId id)
        external
        view
        returns (uint224 reserves, uint256 price1CumulativeLast);

    function observeNow(IPairPoolManager poolManager, PoolStatus memory status)
        external
        view
        returns (uint224 reserves, uint256 price1CumulativeLast);

    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (uint224[] memory reserves, uint256[] memory price1CumulativeLast);
}
