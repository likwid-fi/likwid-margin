// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
// Local
import {IERC6909Accrues} from "../interfaces/external/IERC6909Accrues.sol";
import {PoolStatus} from "../types/PoolStatus.sol";

interface ILendingPoolManager is IERC6909Accrues {
    // ******************** EXTERNAL CALL ********************
    function getGrownRatioX112(uint256 id, uint256 growAmount) external view returns (uint256 accruesRatioX112Grown);

    function computeRealAmount(PoolId poolId, Currency currency, uint256 originalAmount)
        external
        view
        returns (uint256 amount);

    // ******************** POOL CALL ********************
    function updateInterests(uint256 id, int256 interest) external;

    function updateProtocolInterests(address caller, PoolId poolId, Currency currency, uint256 interest)
        external
        returns (uint256 originalAmount);

    function sync(PoolId poolId, PoolStatus memory status) external;

    function mirrorIn(address caller, address receiver, PoolId poolId, Currency currency, uint256 amount)
        external
        returns (uint256 originalAmount);

    function mirrorInRealOut(PoolId poolId, PoolStatus memory status, Currency currency, uint256 amount)
        external
        returns (uint256 exchangeAmount);

    function realIn(address caller, address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        returns (uint256 originalAmount);

    function reserveOut(
        address caller,
        address payer,
        PoolId poolId,
        PoolStatus memory status,
        Currency currency,
        uint256 amount
    ) external;

    // ******************** USER CALL ********************
    function deposit(address sender, address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        payable
        returns (uint256 originalAmount);

    function deposit(address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        payable
        returns (uint256 originalAmount);

    function withdraw(address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        returns (uint256 originalAmount);
}
