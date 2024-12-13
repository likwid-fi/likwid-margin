// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {MarginParams, ReleaseParams} from "../types/MarginParams.sol";
import {HookStatus} from "../types/HookStatus.sol";

interface IMarginFees {
    function getInitialLTV(address hook, PoolId poolId) external view returns (uint24 _initialLTV);

    function getLiquidationLTV(address hook, PoolId poolId) external view returns (uint24 _liquidationLTV);

    function feeTo() external view returns (address);

    function getProtocolMarginFee(address hook, PoolId poolId) external view returns (uint24 _protocolMarginFee);

    function dynamicFee(HookStatus memory status) external view returns (uint24 _fee, uint24 _protocolFee);

    function getPoolFees(address hook, PoolId poolId)
        external
        view
        returns (uint24 _fee, uint24 _marginFee, uint24 _protocolFee, uint24 _protocolMarginFee);

    function getBorrowRateCumulativeLast(HookStatus memory status, bool marginForOne) external view returns (uint256);

    function getBorrowRateCumulativeLast(address hook, PoolId poolId, bool marginForOne)
        external
        view
        returns (uint256);

    function getBorrowRate(HookStatus memory status, bool marginForOne) external view returns (uint256);

    function getBorrowRate(address hook, PoolId poolId, bool marginForOne) external view returns (uint256);

    function getBorrowRate(uint256 realReserve, uint256 mirrorReserve) external view returns (uint256);
}
