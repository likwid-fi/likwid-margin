// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {MarginParams} from "../types/MarginParams.sol";
import {ReleaseParams} from "../types/ReleaseParams.sol";
import {PoolStatus} from "../types/PoolStatus.sol";
import {IMarginLiquidity} from "./IMarginLiquidity.sol";

interface IMarginFees {
    /// @notice Get the address of the fee receiver
    /// @return feeTo The address of the fee receiver
    function feeTo() external view returns (address);

    /// @notice Get the dynamic swap fee from the status of pool
    /// @param _poolManager The address of pool manager
    /// @param status The status of the pool
    /// @return _fee The dynamic fee of swap transaction
    function dynamicFee(address _poolManager, PoolStatus memory status) external view returns (uint24 _fee);

    function getAmountOut(address _poolManager, PoolStatus memory status, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint24 fee, uint256 feeAmount);

    function getAmountIn(address _poolManager, PoolStatus memory status, bool zeroForOne, uint256 amountOut)
        external
        view
        returns (uint256 amountIn, uint24 fee, uint256 feeAmount);

    /// @notice Get the dynamic liquidity fee from the status of pool
    /// @param _poolManager The address of pool manager
    /// @param poolId The pool id
    /// @return _fee The dynamic fee of swap transaction
    /// @return _marginFee The fee of margin transaction
    function getPoolFees(address _poolManager, PoolId poolId) external view returns (uint24 _fee, uint24 _marginFee);

    function computeDiff(address pairPoolManager, PoolStatus memory status, bool marginForOne, int256 diff)
        external
        view
        returns (int256 interest0, int256 interest1, int256 lendingInterest);

    function getMarginBorrow(PoolStatus memory status, MarginParams memory params)
        external
        view
        returns (uint256 marginWithoutFee, uint256 marginFeeAmount, uint256 borrowAmount);

    function getBorrowMaxAmount(
        PoolStatus memory status,
        uint256 marginAmount,
        bool marginForOne,
        uint256 minMarginLevel
    ) external view returns (uint256 borrowMaxAmount);

    /// @notice Get the borrow rate from the reserves
    /// @param realReserve The real reserve of the pool
    /// @param mirrorReserve The mirror reserve of the pool
    /// @return The borrow rate
    function getBorrowRateByReserves(uint256 realReserve, uint256 mirrorReserve) external view returns (uint256);

    /// @notice Get the last cumulative multiplication of rate
    /// @param status The status of the hook
    /// @return rate0CumulativeLast The currency0 last cumulative multiplication of rate
    /// @return rate1CumulativeLast The currency1 last cumulative multiplication of rate
    function getBorrowRateCumulativeLast(PoolStatus memory status)
        external
        view
        returns (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast);

    /// @notice Get the last cumulative multiplication of rate
    /// @param pool The address of pool
    /// @param poolId The pool id
    /// @param marginForOne true: currency1 is marginToken, false: currency0 is marginToken
    /// @return The last cumulative multiplication of rate
    function getBorrowRateCumulativeLast(address pool, PoolId poolId, bool marginForOne)
        external
        view
        returns (uint256);

    /// @notice Get the current borrow rate
    /// @param status The status of the pool
    /// @param marginForOne true: currency1 is marginToken, false: currency0 is marginToken
    /// @return The current borrow rate
    function getBorrowRate(PoolStatus memory status, bool marginForOne) external view returns (uint256);

    /// @notice Get the current borrow rate
    /// @param pool The address of pool
    /// @param poolId The pool id
    /// @param marginForOne true: currency1 is marginToken, false: currency0 is marginToken
    /// @return The current borrow rate
    function getBorrowRate(address pool, PoolId poolId, bool marginForOne) external view returns (uint256);

    /// @notice Get the protocol part of the totalFee
    /// @param totalFee Total fee amount
    /// @return feeAmount The protocol part fee amount
    function getProtocolFeeAmount(uint256 totalFee) external view returns (uint256 feeAmount);

    /// @notice Collects the protocol fees for a given recipient and currency, returning the amount collected
    /// @param poolManager The address of pool manager
    /// @param recipient The address to receive the protocol fees
    /// @param currency The currency to withdraw
    /// @param amount The amount of currency to withdraw
    /// @return amountCollected The amount of currency successfully withdrawn
    function collectProtocolFees(address poolManager, address recipient, Currency currency, uint256 amount)
        external
        returns (uint256);
}
