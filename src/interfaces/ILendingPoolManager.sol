// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
// Local
import {IERC6909Accrues} from "../interfaces/external/IERC6909Accrues.sol";

interface ILendingPoolManager is IERC6909Accrues {
    // ******************** EXTERNAL CALL ********************
    function computeRealAmount(PoolId poolId, Currency currency, uint256 originalAmount)
        external
        view
        returns (uint256 amount);

    // ******************** POOL CALL ********************
    function updateInterests(uint256 id, int256 interest) external;

    function updateProtocolInterests(PoolId poolId, Currency currency, uint256 interest)
        external
        returns (uint256 originalAmount);

    function balanceAccounts(Currency currency, uint256 amount) external;

    function mirrorIn(address receiver, PoolId poolId, Currency currency, uint256 amount)
        external
        returns (uint256 originalAmount);

    function mirrorInRealOut(PoolId poolId, Currency currency, uint256 amount)
        external
        returns (uint256 exchangeAmount);

    function realIn(address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        returns (uint256 originalAmount);

    function realOut(address sender, PoolId poolId, Currency currency, uint256 amount) external;

    // ******************** USER CALL ********************
    function deposit(address sender, address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        payable
        returns (uint256 originalAmount);

    function deposit(address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        payable
        returns (uint256 originalAmount);

    function withdraw(address recipient, PoolId poolId, Currency currency, uint256 amount) external;
}
