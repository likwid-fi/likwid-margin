// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

import {AddLiquidityParams, RemoveLiquidityParams} from "../types/LiquidityParams.sol";
import {ReleaseParams} from "../types/ReleaseParams.sol";
import {PoolStatus} from "../types/PoolStatus.sol";
import {IPairMarginManager} from "./IPairMarginManager.sol";
import {IMarginFees} from "./IMarginFees.sol";
import {IMarginLiquidity} from "./IMarginLiquidity.sol";
import {ILendingPoolManager} from "./ILendingPoolManager.sol";
import {IPoolStatusManager} from "./IPoolStatusManager.sol";

interface IPairPoolManager is IPairMarginManager {
    function hooks() external view returns (IHooks hook);

    function positionManagers(address _positionManager) external view returns (bool);

    function lendingPoolManager() external view returns (ILendingPoolManager);

    function statusManager() external view returns (IPoolStatusManager);

    /// @notice Get current IMarginFees
    function marginFees() external view returns (IMarginFees);

    /// @notice Get current IMarginLiquidity
    function marginLiquidity() external view returns (IMarginLiquidity);

    /// @notice Get status of a pool
    /// @param poolId The poolId of the pool to query
    /// @return status The current status of the pool
    function getStatus(PoolId poolId) external view returns (PoolStatus memory);

    /// @notice Get the reserves of a pool
    /// @param poolId The poolId of the pool to query
    /// @return _reserve0 The reserve of the first token in the pool
    /// @return _reserve1 The reserve of the second token in the pool
    function getReserves(PoolId poolId) external view returns (uint256 _reserve0, uint256 _reserve1);

    /// @notice Given an output amount of an asset and pair reserve, returns a required input amount of the other asset
    /// @param poolId The poolId of the pool to query
    /// @param zeroForOne If true, the input asset is the first token of the pair, otherwise it is the second token
    /// @param amountOut an output amount
    /// @return amountIn a required input amount
    function getAmountIn(PoolId poolId, bool zeroForOne, uint256 amountOut) external view returns (uint256 amountIn);

    /// @notice Given an input amount of an asset and pair reserve, returns the expected output amount of the other asset
    /// @param poolId The poolId of the pool to query
    /// @param zeroForOne If true, the input asset is the first token of the pair, otherwise it is the second token
    /// @param amountIn a input amount
    /// @return amountOut an output amount
    function getAmountOut(PoolId poolId, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut);

    // ******************** HOOK CALL ********************

    function initialize(PoolKey calldata key) external;

    function swap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        returns (
            Currency specified,
            Currency unspecified,
            uint256 specifiedAmount,
            uint256 unspecifiedAmount,
            uint24 swapFee
        );
    // ******************** USER CALL ********************

    /// @notice Add liquidity to a pool
    /// @param params The parameters for the add liquidity hook
    /// @return liquidity The amount of liquidity minted
    function addLiquidity(AddLiquidityParams calldata params) external payable returns (uint256 liquidity);

    /// @notice Remove liquidity from a pool
    /// @param params The parameters for the remove liquidity hook
    /// @return amount0 The amount of token0 repaid
    /// @return amount1 The amount of token1 repaid
    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    // ******************** EXTERNAL FUNCTIONS ********************

    function mirrorInRealOut(PoolId poolId, PoolStatus memory status, Currency currency, uint256 amount)
        external
        returns (bool success);

    function swapMirror(address sender, address recipient, PoolId poolId, bool zeroForOne, uint256 amountIn)
        external
        payable
        returns (uint256 amountOut);

    /// @notice Collects the protocol fees for a given recipient and currency, returning the amount collected
    /// @dev This will revert if the contract is unlocked
    /// @param recipient The address to receive the protocol fees
    /// @param currency The currency to withdraw
    /// @param amount The amount of currency to withdraw
    /// @return amountCollected The amount of currency successfully withdrawn
    function collectProtocolFees(address recipient, Currency currency, uint256 amount) external returns (uint256);
}
