// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
// V4 core
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {PerLibrary} from "../libraries/PerLibrary.sol";
import {PoolStatus} from "../types/PoolStatus.sol";
import {MarginParams} from "../types/MarginParams.sol";
import {ReentrancyGuardTransient} from "../external/openzeppelin-contracts/ReentrancyGuardTransient.sol";
import {IPairPoolManager} from "../interfaces/IPairPoolManager.sol";
import {ILendingPoolManager} from "../interfaces/ILendingPoolManager.sol";
import {IMarginChecker} from "../interfaces/IMarginChecker.sol";

abstract contract BasePositionManager is ERC721, Owned, ReentrancyGuardTransient {
    using PerLibrary for *;

    uint256 public nextId = 1;

    IPairPoolManager public immutable pairPoolManager;
    ILendingPoolManager public immutable lendingPoolManager;
    IMarginChecker public checker;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    constructor(
        string memory name,
        string memory symbol,
        address initialOwner,
        IPairPoolManager _pairPoolManager,
        IMarginChecker _checker
    ) ERC721(name, symbol) Owned(initialOwner) {
        pairPoolManager = _pairPoolManager;
        lendingPoolManager = _pairPoolManager.getLendingPoolManager();
        checker = _checker;
    }

    function transferNative(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success, "TRANSFER_FAILED");
    }

    function _checkMinMarginLevel(MarginParams memory params, PoolStatus memory _status)
        internal
        view
        returns (bool valid)
    {
        (uint256 reserve0, uint256 reserve1) =
            (_status.realReserve0 + _status.mirrorReserve0, _status.realReserve1 + _status.mirrorReserve1);
        (uint256 reserveBorrow, uint256 reserveMargin) =
            params.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 debtAmount = reserveMargin * params.borrowAmount / reserveBorrow;
        valid = params.marginAmount + params.marginTotal >= debtAmount.mulDivMillion(checker.minMarginLevel());
    }

    // ******************** OWNER CALL ********************
    function setMarginChecker(address _checker) external onlyOwner {
        checker = IMarginChecker(_checker);
    }
}
