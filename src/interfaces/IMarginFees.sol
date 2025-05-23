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

    function marginFee() external view returns (uint24);

    /// @notice Get the dynamic swap fee from the status of pool
    /// @param status The status of the pool
    /// @param zeroForOne if true amountIn is currency0,else amountIn is currency1
    /// @param amountIn The amount swap in
    /// @param amountOut The amount swap out
    /// @return _fee The dynamic fee of swap transaction
    function dynamicFee(PoolStatus memory status, bool zeroForOne, uint256 amountIn, uint256 amountOut)
        external
        view
        returns (uint24 _fee);

    /// @notice Get the dynamic liquidity fee from the status of pool
    /// @param _poolManager The address of pool manager
    /// @param poolId The pool id
    /// @param zeroForOne if true amountIn is currency0,else amountIn is currency1
    /// @param amountIn The amount swap in
    /// @param amountOut The amount swap out
    /// @return _fee The dynamic fee of swap transaction
    /// @return _marginFee The fee of margin transaction
    function getPoolFees(address _poolManager, PoolId poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut)
        external
        view
        returns (uint24 _fee, uint24 _marginFee);

    /// @notice Get the borrow rate from the reserves
    /// @param realReserve The real reserve of the pool
    /// @param mirrorReserve The mirror reserve of the pool
    /// @return The borrow rate
    function getBorrowRateByReserves(uint256 realReserve, uint256 mirrorReserve) external view returns (uint256);

    /// @notice Get the last cumulative multiplication of rate
    /// @param interestReserve0 The interest reserve of the first currency
    /// @param interestReserve1 The interest reserve of the second currency
    /// @param status The status of the pairPool
    /// @return rate0CumulativeLast The currency0 last cumulative multiplication of rate
    /// @return rate1CumulativeLast The currency1 last cumulative multiplication of rate
    function getBorrowRateCumulativeLast(uint256 interestReserve0, uint256 interestReserve1, PoolStatus memory status)
        external
        view
        returns (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast);

    /// @notice Get the last cumulative multiplication of rate
    /// @param pairPoolManager The address of pairPoolManager
    /// @param poolId The pool id
    /// @param marginForOne true: currency1 is marginToken, false: currency0 is marginToken
    /// @return The last cumulative multiplication of rate
    function getBorrowRateCumulativeLast(address pairPoolManager, PoolId poolId, bool marginForOne)
        external
        view
        returns (uint256);

    /// @notice Get the current borrow rate
    /// @param pairPoolManager The address of pairPoolManager
    /// @param status The status of the pool
    /// @param marginForOne true: currency1 is marginToken, false: currency0 is marginToken
    /// @return The current borrow rate
    function getBorrowRate(address pairPoolManager, PoolStatus memory status, bool marginForOne)
        external
        view
        returns (uint256);

    /// @notice Get the current borrow rate
    /// @param pairPoolManager The address of pairPoolManager
    /// @param poolId The pool id
    /// @param marginForOne true: currency1 is marginToken, false: currency0 is marginToken
    /// @return The current borrow rate
    function getBorrowRate(address pairPoolManager, PoolId poolId, bool marginForOne) external view returns (uint256);

    /// @notice Get the protocol part of the totalFee
    /// @param totalFee Total fee amount
    /// @return feeAmount The protocol part fee amount
    function getProtocolSwapFeeAmount(uint256 totalFee) external view returns (uint256 feeAmount);
    function getProtocolMarginFeeAmount(uint256 totalFee) external view returns (uint256 feeAmount);
    function getProtocolInterestFeeAmount(uint256 totalFee) external view returns (uint256 feeAmount);

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
