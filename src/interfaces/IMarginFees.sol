// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {MarginParams, ReleaseParams} from "../types/MarginParams.sol";
import {HookStatus} from "../types/HookStatus.sol";
import {IMarginLiquidity} from "./IMarginLiquidity.sol";

interface IMarginFees {
    /// @notice Get the liquidation margin level
    /// @return liquidationMarginLevel The liquidation margin level
    function liquidationMarginLevel() external view returns (uint24);

    /// @notice Get the address of the fee receiver
    /// @return feeTo The address of the fee receiver
    function feeTo() external view returns (address);

    /// @notice Get the dynamic swap fee from the status of pool
    /// @param status The status of the hook
    /// @return _fee The dynamic fee of swap transaction
    function dynamicFee(HookStatus memory status) external view returns (uint24 _fee);

    /// @notice Get the dynamic liquidity fee from the status of pool
    /// @param hook The address of hook
    /// @param poolId The pool id
    /// @return _fee The dynamic fee of swap transaction
    /// @return _marginFee The fee of margin transaction
    function getPoolFees(address hook, PoolId poolId) external view returns (uint24 _fee, uint24 _marginFee);

    /// @notice Get the borrow rate from the reserves
    /// @param realReserve The real reserve of the pool
    /// @param mirrorReserve The mirror reserve of the pool
    /// @return The borrow rate
    function getBorrowRateByReserves(uint256 realReserve, uint256 mirrorReserve) external view returns (uint256);

    /// @notice Get the last cumulative multiplication of rate
    /// @param status The status of the hook
    /// @param marginForOne true: currency1 is marginToken, false: currency0 is marginToken
    /// @return The last cumulative multiplication of rate
    function getBorrowRateCumulativeLast(HookStatus memory status, bool marginForOne) external view returns (uint256);

    /// @notice Get the last cumulative multiplication of rate
    /// @param hook The address of hook
    /// @param poolId The pool id
    /// @param marginForOne true: currency1 is marginToken, false: currency0 is marginToken
    /// @return The last cumulative multiplication of rate
    function getBorrowRateCumulativeLast(address hook, PoolId poolId, bool marginForOne)
        external
        view
        returns (uint256);

    /// @notice Get the current borrow rate
    /// @param status The status of the hook
    /// @param marginForOne true: currency1 is marginToken, false: currency0 is marginToken
    /// @return The current borrow rate
    function getBorrowRate(HookStatus memory status, bool marginForOne) external view returns (uint256);

    /// @notice Get the current borrow rate
    /// @param hook The address of hook
    /// @param poolId The pool id
    /// @param marginForOne true: currency1 is marginToken, false: currency0 is marginToken
    /// @return The current borrow rate
    function getBorrowRate(address hook, PoolId poolId, bool marginForOne) external view returns (uint256);

    /// @notice Get the interests of the pool
    /// @param status The status of the hook
    /// @return interest0 The interest of currency0
    /// @return interest1 The interest of currency1
    function getInterests(HookStatus calldata status) external pure returns (uint112 interest0, uint112 interest1);

    /// @notice Get the interests of the pool
    /// @param hook The address of hook
    /// @param poolId The pool id
    /// @return interest0 The interest of currency0
    /// @return interest1 The interest of currency1
    function getInterests(address hook, PoolId poolId) external view returns (uint112 interest0, uint112 interest1);
}
