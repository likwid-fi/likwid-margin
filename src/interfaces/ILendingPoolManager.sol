// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
// Local
import {IERC6909Accrues} from "../interfaces/external/IERC6909Accrues.sol";

interface ILendingPoolManager is IERC6909Accrues {
    function updateInterests(uint256 id, uint256 interest) external;

    function mirrorIn(PoolId poolId, Currency currency, uint256 amount) external returns (uint256 lendingAmount);

    function mirrorToReal(PoolId poolId, Currency currency, uint256 amount) external returns (uint256 exchangeAmount);

    function realIn(address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        returns (uint256 lendingAmount);

    function deposit(address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        payable
        returns (uint256 lendingAmount);

    function withdraw(address recipient, PoolId poolId, Currency currency, uint256 amount) external;
}
