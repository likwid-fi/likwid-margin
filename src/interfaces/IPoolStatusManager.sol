// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {IStatusBase} from "./IStatusBase.sol";
import {BalanceStatus} from "../types/BalanceStatus.sol";
import {PoolStatus} from "../types/PoolStatus.sol";

interface IPoolStatusManager is IStatusBase {
    function hooks() external view returns (IHooks hook);

    /// @notice Get current margin oracle address
    function marginOracle() external view returns (address);

    function initialize(PoolKey calldata key) external;

    function getStatus(PoolId poolId) external view returns (PoolStatus memory _status);

    function protocolFeesAccrued(Currency currency) external view returns (uint256);

    function setBalances(PoolId poolId) external returns (PoolStatus memory _status);

    function updateInterests(PoolId poolId) external returns (PoolStatus memory _status);

    function storeBalances(PoolKey memory key) external;

    function update(PoolId poolId, bool fromMargin) external returns (BalanceStatus memory afterStatus);

    function update(PoolId poolId) external returns (BalanceStatus memory afterStatus);

    function updateLendingPoolStatus(PoolId poolId) external;

    function updateProtocolFees(Currency currency, uint256 amount) external returns (uint256 restAmount);

    function collectProtocolFees(Currency currency, uint256 amount) external returns (uint256 amountCollected);
}
