// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// Local
import {GlobalStatus} from "./types/GlobalStatus.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {MarginParams, MarginParamsVo} from "./types/MarginParams.sol";
import {LiquidateStatus} from "./types/LiquidateStatus.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {MarginPosition, MarginPositionVo} from "./types/MarginPosition.sol";
import {IStatusBase} from "./interfaces/IStatusBase.sol";
import {IPairMarginManager} from "./interfaces/IPairMarginManager.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IMarginChecker} from "./interfaces/IMarginChecker.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";

contract MarginChecker is IMarginChecker, Owned {
    using UQ112x112 for *;
    using PerLibrary for uint256;
    using FeeLibrary for uint24;
    using PoolStatusLibrary for PoolStatus;

    error LeverageOverflow();

    event StateChanged(string name, uint24 oldValue, uint24 newValue);

    uint24 public maxLeverage = 5;
    uint24 public liquidationMarginLevel = 1100000; // 110%
    uint24 public minMarginLevel = 1170000; // 117%
    uint24 public minBorrowLevel = 1400000; // 140%
    uint24 public liquidationRatio = 950000; // 95%
    uint24 callerProfit = 10000;
    uint24 protocolProfit = 5000;

    constructor(address initialOwner) Owned(initialOwner) {}

    // ******************** OWNER CALL ********************
    function setCallerProfit(uint24 _callerProfit) external onlyOwner {
        emit StateChanged("callerProfit", callerProfit, _callerProfit);
        callerProfit = _callerProfit;
    }

    function setProtocolProfit(uint24 _protocolProfit) external onlyOwner {
        emit StateChanged("protocolProfit", protocolProfit, _protocolProfit);
        protocolProfit = _protocolProfit;
    }

    function setMaxLeverage(uint24 _maxLeverage) external onlyOwner {
        emit StateChanged("maxLeverage", maxLeverage, _maxLeverage);
        maxLeverage = _maxLeverage;
    }

    function setLiquidationMarginLevel(uint24 _liquidationMarginLevel) external onlyOwner {
        emit StateChanged("liquidationMarginLevel", liquidationMarginLevel, _liquidationMarginLevel);
        liquidationMarginLevel = _liquidationMarginLevel;
    }

    function setMinMarginLevel(uint24 _minMarginLevel) external onlyOwner {
        emit StateChanged("minMarginLevel", minMarginLevel, _minMarginLevel);
        minMarginLevel = _minMarginLevel;
    }

    function setLiquidationRatio(uint24 _liquidationRatio) external onlyOwner {
        emit StateChanged("liquidationRatio", liquidationRatio, _liquidationRatio);
        liquidationRatio = _liquidationRatio;
    }

    function setMinBorrowLevel(uint24 _minBorrowLevel) external onlyOwner {
        emit StateChanged("minBorrowLevel", minBorrowLevel, _minBorrowLevel);
        minBorrowLevel = _minBorrowLevel;
    }

    // ******************** EXTERNAL CALL ********************
    /// @inheritdoc IMarginChecker
    function getProfitMillions() external view returns (uint24, uint24) {
        return (callerProfit, protocolProfit);
    }

    /// @inheritdoc IMarginChecker
    function checkValidity(address, uint256) external pure returns (bool) {
        // At the current stage, return true always.
        return true;
    }

    function _getReserves(PoolStatus memory status, bool marginForOne)
        internal
        pure
        returns (uint256 reserveBorrow, uint256 reserveMargin)
    {
        (reserveBorrow, reserveMargin) = marginForOne
            ? (status.truncatedReserve0, status.truncatedReserve1)
            : (status.truncatedReserve1, status.truncatedReserve0);
    }

    /// @inheritdoc IMarginChecker
    function getReserves(address _poolManager, PoolId poolId, bool marginForOne)
        public
        view
        returns (uint256 reserveBorrow, uint256 reserveMargin)
    {
        IPairPoolManager poolManager = IPairPoolManager(_poolManager);
        PoolStatus memory status = poolManager.getStatus(poolId);
        (reserveBorrow, reserveMargin) = _getReserves(status, marginForOne);
    }

    function _estimatePNL(IMarginPositionManager positionManager, uint256 positionId, uint256 closeMillionth)
        internal
        view
        returns (MarginPositionVo memory _positionVo)
    {
        IPairPoolManager pairPoolManager = IPairPoolManager(IStatusBase(address(positionManager)).pairPoolManager());
        MarginPosition memory _position = positionManager.getPosition(positionId);
        if (_position.borrowAmount == 0 || closeMillionth == 0) {
            _positionVo.pnl = 0;
        } else {
            uint256 repayAmount = uint256(_position.borrowAmount).mulDivMillion(closeMillionth);
            if (_position.marginTotal == 0) {
                uint256 repayValue = pairPoolManager.getAmountOut(_position.poolId, _position.marginForOne, repayAmount);
                uint256 releaseAmount = uint256(_position.marginAmount).mulDivMillion(closeMillionth);
                _positionVo.pnl = int256(releaseAmount) - int256(repayValue);
            } else {
                uint256 releaseAmount =
                    pairPoolManager.getAmountIn(_position.poolId, !_position.marginForOne, repayAmount);
                uint256 releaseTotal = uint256(_position.marginTotal).mulDivMillion(closeMillionth);
                _positionVo.pnl = int256(releaseTotal) - int256(releaseAmount);
            }
        }
        _positionVo.position = _position;
    }

    function estimatePNL(IMarginPositionManager positionManager, uint256 positionId, uint256 closeMillionth)
        public
        view
        returns (int256 pnlAmount)
    {
        pnlAmount = _estimatePNL(positionManager, positionId, closeMillionth).pnl;
    }

    function checkMinMarginLevel(
        PoolStatus memory _status,
        bool marginForOne,
        uint256 leverage,
        uint256 assetsAmount,
        uint256 debtAmount
    ) external view returns (bool valid) {
        if (leverage > maxLeverage) revert LeverageOverflow();

        uint256 repayAmount;
        (uint256 reserveBorrow, uint256 reserveMargin) = _getReserves(_status, marginForOne);

        if (leverage > 0) {
            repayAmount = Math.mulDiv(reserveBorrow, assetsAmount, reserveMargin);
            repayAmount = repayAmount.mulMillionDiv(minMarginLevel);
        } else {
            uint256 numerator = assetsAmount * reserveBorrow;
            uint256 denominator = reserveMargin + assetsAmount;
            repayAmount = numerator / denominator;
            repayAmount = repayAmount.mulMillionDiv(minBorrowLevel);
        }
        valid = debtAmount <= repayAmount;
    }

    function getLiquidateRepayAmount(PoolStatus memory _status, bool marginForOne, uint256 assetsAmount)
        public
        view
        returns (uint256 repayAmount)
    {
        (uint256 reserveBorrow, uint256 reserveMargin) = _getReserves(_status, marginForOne);
        repayAmount = Math.mulDiv(reserveBorrow, assetsAmount, reserveMargin);
        repayAmount = repayAmount.mulDivMillion(liquidationRatio);
    }

    function getLiquidateRepayAmount(address manager, uint256 positionId) external view returns (uint256 repayAmount) {
        IMarginPositionManager positionManager = IMarginPositionManager(manager);
        MarginPosition memory _position = positionManager.getPosition(positionId);
        IPairPoolManager pairPoolManager = IPairPoolManager(IStatusBase(manager).pairPoolManager());
        PoolStatus memory _status = pairPoolManager.statusManager().getStatus(_position.poolId);
        return getLiquidateRepayAmount(_status, _position.marginForOne, _position.marginAmount + _position.marginTotal);
    }

    function updatePosition(IMarginPositionManager positionManager, MarginPosition memory _position)
        external
        view
        returns (MarginPosition memory)
    {
        IPairPoolManager pairPoolManager = IPairPoolManager(IStatusBase(address(positionManager)).pairPoolManager());
        if (_position.rateCumulativeLast > 0) {
            uint256 rateCumulativeLast = pairPoolManager.marginFees().getBorrowRateCumulativeLast(
                address(pairPoolManager), _position.poolId, _position.marginForOne
            );
            if (_position.rateCumulativeLast < rateCumulativeLast) {
                _position.borrowAmount =
                    _position.borrowAmount.increaseInterestCeil(_position.rateCumulativeLast, rateCumulativeLast);
                _position.rateCumulativeLast = rateCumulativeLast;
            }
            GlobalStatus memory globalStatus = pairPoolManager.statusManager().getGlobalStatus(_position.poolId);
            uint256 accruesRatioX112 = _position.marginForOne
                ? globalStatus.lendingStatus.accruesRatio1X112
                : globalStatus.lendingStatus.accruesRatio0X112;
            _position.marginAmount = uint256(_position.marginAmount).mulRatioX112(accruesRatioX112).toUint112();
            _position.marginTotal = uint256(_position.marginTotal).mulRatioX112(accruesRatioX112).toUint112();
        }
        return _position;
    }

    function getPositions(IMarginPositionManager positionManager, uint256[] calldata positionIds)
        external
        view
        returns (MarginPositionVo[] memory _position)
    {
        _position = new MarginPositionVo[](positionIds.length);
        for (uint256 i = 0; i < positionIds.length; i++) {
            _position[i] = _estimatePNL(positionManager, positionIds[i], PerLibrary.ONE_MILLION);
        }
    }

    function _getMaxDecrease(
        address _poolManager,
        PoolStatus memory _status,
        MarginPosition memory _position,
        bool computeRealAmount
    ) internal view returns (uint256 maxAmount) {
        IPairPoolManager poolManager = IPairPoolManager(_poolManager);
        (uint256 reserveBorrow, uint256 reserveMargin) = _getReserves(_status, _position.marginForOne);
        uint256 needAmount;
        uint256 debtAmount = uint256(_position.borrowAmount).mulDivMillion(minBorrowLevel);
        if (_position.marginTotal > 0) {
            needAmount = Math.mulDiv(reserveMargin, debtAmount, reserveBorrow);
        } else {
            needAmount = _status.getAmountIn(!_position.marginForOne, debtAmount);
        }
        Currency marginCurrency = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        uint256 assetAmount = _position.marginAmount + _position.marginTotal;
        if (computeRealAmount) {
            assetAmount =
                poolManager.lendingPoolManager().computeRealAmount(_position.poolId, marginCurrency, assetAmount);
        }
        if (needAmount < assetAmount) {
            maxAmount = assetAmount - needAmount;
        }
        maxAmount = Math.min(uint256(_position.marginAmount), maxAmount);
    }

    /// @inheritdoc IMarginChecker
    function getMaxDecrease(address _poolManager, PoolStatus memory _status, MarginPosition memory _position)
        public
        view
        returns (uint256 maxAmount)
    {
        maxAmount = _getMaxDecrease(_poolManager, _status, _position, true);
    }

    function getMaxDecrease(address positionManager, uint256 positionId) external view returns (uint256 maxAmount) {
        IMarginPositionManager manager = IMarginPositionManager(positionManager);
        MarginPosition memory _position = manager.getPosition(positionId);
        address _poolManager = IStatusBase(positionManager).pairPoolManager();
        IPairPoolManager poolManager = IPairPoolManager(_poolManager);
        PoolStatus memory _status = poolManager.getStatus(_position.poolId);
        maxAmount = _getMaxDecrease(_poolManager, _status, _position, false);
    }

    function _checkLiquidate(
        IPairMarginManager poolManager,
        PoolStatus memory _status,
        MarginPosition memory _position,
        bool computeRealAmount
    ) internal view returns (bool liquidated, uint256 borrowAmount) {
        if (_position.borrowAmount > 0) {
            borrowAmount = uint256(_position.borrowAmount);
            uint256 assetAmount = _position.marginAmount + _position.marginTotal;
            Currency marginCurrency = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
            if (_position.rateCumulativeLast > 0) {
                uint256 rateCumulativeLast =
                    _position.marginForOne ? _status.rate0CumulativeLast : _status.rate1CumulativeLast;
                if (_position.rateCumulativeLast < rateCumulativeLast) {
                    borrowAmount =
                        _position.borrowAmount.increaseInterestCeil(_position.rateCumulativeLast, rateCumulativeLast);
                }
            }
            // call from repay/close/liquidateBurn/liquidateCall
            if (computeRealAmount) {
                assetAmount =
                    poolManager.lendingPoolManager().computeRealAmount(_position.poolId, marginCurrency, assetAmount);
            }
            (uint256 reserveBorrow, uint256 reserveMargin) = _getReserves(_status, _position.marginForOne);
            uint256 repayAmount;
            if (_position.marginTotal > 0) {
                repayAmount = Math.mulDiv(reserveBorrow, assetAmount, reserveMargin);
            } else {
                uint256 numerator = assetAmount * reserveBorrow;
                uint256 denominator = reserveMargin + assetAmount;
                repayAmount = numerator / denominator;
            }
            uint256 liquidatedAmount = repayAmount.mulMillionDiv(liquidationMarginLevel);
            // debt exceeds assets
            liquidated = _position.borrowAmount > liquidatedAmount;
        }
    }

    /// @inheritdoc IMarginChecker
    function checkLiquidate(address manager, uint256 positionId)
        public
        view
        returns (bool liquidated, uint256 borrowAmount)
    {
        IMarginPositionManager positionManager = IMarginPositionManager(manager);
        MarginPosition memory _position = positionManager.getPosition(positionId);
        IPairPoolManager pairPoolManager = IPairPoolManager(IStatusBase(manager).pairPoolManager());
        PoolStatus memory _status = pairPoolManager.statusManager().getStatus(_position.poolId);
        return _checkLiquidate(pairPoolManager, _status, _position, false);
    }

    /// @inheritdoc IMarginChecker
    function checkLiquidate(address manager, uint256[] calldata positionIds)
        external
        view
        returns (bool[] memory liquidatedList, uint256[] memory borrowAmountList)
    {
        liquidatedList = new bool[](positionIds.length);
        borrowAmountList = new uint256[](positionIds.length);
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 positionId = positionIds[i];
            (liquidatedList[i], borrowAmountList[i]) = checkLiquidate(manager, positionId);
        }
    }

    /// @inheritdoc IMarginChecker
    function checkLiquidate(IPairMarginManager poolManager, PoolStatus memory _status, MarginPosition memory _position)
        external
        view
        returns (bool liquidated, uint256 borrowAmount)
    {
        return _checkLiquidate(poolManager, _status, _position, true);
    }
}
