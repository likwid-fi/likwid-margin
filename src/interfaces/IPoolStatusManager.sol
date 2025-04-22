// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {IStatusBase} from "./IStatusBase.sol";
import {IMarginFees} from "./IMarginFees.sol";
import {BalanceStatus} from "../types/BalanceStatus.sol";
import {PoolStatus} from "../types/PoolStatus.sol";
import {GlobalStatus} from "../types/GlobalStatus.sol";

interface IPoolStatusManager is IStatusBase {
    function hooks() external view returns (IHooks hook);

    /// @notice Get current IMarginFees
    function marginFees() external view returns (IMarginFees hook);

    function initialize(PoolKey calldata key) external;

    function getGlobalStatus(PoolId poolId) external view returns (GlobalStatus memory _status);

    function getStatus(PoolId poolId) external view returns (PoolStatus memory _status);

    function getAmountOut(PoolStatus memory status, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint24 fee, uint256 feeAmount);

    function getAmountIn(PoolStatus memory status, bool zeroForOne, uint256 amountOut)
        external
        view
        returns (uint256 amountIn, uint24 fee, uint256 feeAmount);

    function protocolFeesAccrued(Currency currency) external view returns (uint256);

    function setBalances(address sender, PoolId poolId) external returns (PoolStatus memory _status);

    function update(PoolId poolId) external;

    function updateSwapProtocolFees(Currency currency, uint256 amount) external returns (uint256 restAmount);

    function updateMarginProtocolFees(Currency currency, uint256 amount) external returns (uint256 restAmount);

    function collectProtocolFees(Currency currency, uint256 amount) external returns (uint256 amountCollected);
}
