// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

interface IMarginOracleReader {
    function observeNow(PoolId id, address hook)
        external
        view
        returns (uint224 reserves, uint256 price1CumulativeLast);

    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (uint224[] memory reserves, uint256[] memory price1CumulativeLast);
}
