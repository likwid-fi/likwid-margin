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

    function getBorrowRateCumulativeLast(HookStatus memory status)
        external
        view
        returns (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast);

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

    /// @notice Get the protocol part of the totalFee
    /// @param totalFee Total fee amount
    /// @return feeAmount The protocol part fee amount
    function getProtocolFeeAmount(uint256 totalFee) external view returns (uint256 feeAmount);

    /// @notice Collects the protocol fees for a given recipient and currency, returning the amount collected
    /// @param hook The address of hook
    /// @param recipient The address to receive the protocol fees
    /// @param currency The currency to withdraw
    /// @param amount The amount of currency to withdraw
    /// @return amountCollected The amount of currency successfully withdrawn
    function collectProtocolFees(address hook, address recipient, Currency currency, uint256 amount)
        external
        returns (uint256);
}
