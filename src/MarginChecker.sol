// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// Local
import {PoolStatus} from "./types/PoolStatus.sol";
import {PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {MarginParams, MarginParamsVo} from "./types/MarginParams.sol";
import {LiquidateStatus} from "./types/LiquidateStatus.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {MarginPosition, MarginPositionVo} from "./types/MarginPosition.sol";
import {IStatusBase} from "./interfaces/IStatusBase.sol";
import {IPairMarginManager} from "./interfaces/IPairMarginManager.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IMarginChecker} from "./interfaces/IMarginChecker.sol";
import {IMarginOracleReader} from "./interfaces/IMarginOracleReader.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";

contract MarginChecker is IMarginChecker, Owned {
    using UQ112x112 for *;
    using PriceMath for uint224;
    using PerLibrary for uint256;
    using FeeLibrary for uint24;
    using PoolStatusLibrary for PoolStatus;

    uint24 public liquidationMarginLevel = 1100000; // 110%
    uint24 public minMarginLevel = 1170000; // 117%
    uint24 callerProfit = 10 ** 4;
    uint24 protocolProfit = 0;
    uint24[] leverageThousandths = [380, 200, 100, 40, 9];

    constructor(address initialOwner) Owned(initialOwner) {}

    // ******************** OWNER CALL ********************
    function setCallerProfit(uint24 _callerProfit) external onlyOwner {
        callerProfit = _callerProfit;
    }

    function setProtocolProfit(uint24 _protocolProfit) external onlyOwner {
        protocolProfit = _protocolProfit;
    }

    function setLiquidationMarginLevel(uint24 _liquidationMarginLevel) external onlyOwner {
        liquidationMarginLevel = _liquidationMarginLevel;
    }

    function setMinMarginLevel(uint24 _minMarginLevel) external onlyOwner {
        minMarginLevel = _minMarginLevel;
    }

    // ******************** EXTERNAL CALL ********************
    /// @inheritdoc IMarginChecker
    function getProfitMillions() external view returns (uint24, uint24) {
        return (callerProfit, protocolProfit);
    }

    function setLeverageParts(uint24[] calldata _leverageThousandths) external onlyOwner {
        leverageThousandths = _leverageThousandths;
    }

    /// @inheritdoc IMarginChecker
    function getThousandthsByLeverage() external view returns (uint24[] memory) {
        return leverageThousandths;
    }

    /// @inheritdoc IMarginChecker
    function checkValidity(address, uint256) external pure returns (bool) {
        // At the current stage, return true always.
        return true;
    }

    function estimatePNL(
        IPairMarginManager pairPoolManager,
        PoolStatus memory _status,
        MarginPosition memory _position,
        uint256 closeMillionth
    ) public view returns (int256 pnlAmount) {
        if (_position.borrowAmount == 0 || closeMillionth == 0) {
            return 0;
        }
        Currency marginCurrency = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        uint256 repayAmount = uint256(_position.borrowAmount).mulDivMillion(closeMillionth);
        uint256 releaseAmount;
        if (_position.marginTotal == 0) {
            releaseAmount = pairPoolManager.getAmountOut(_position.poolId, _position.marginForOne, repayAmount);
        } else {
            releaseAmount = pairPoolManager.getAmountIn(_position.poolId, !_position.marginForOne, repayAmount);
        }
        uint256 releaseTotal = uint256(_position.marginTotal).mulDivMillion(closeMillionth);
        uint256 releaseTotalReal =
            pairPoolManager.lendingPoolManager().computeRealAmount(_position.poolId, marginCurrency, releaseTotal);
        pnlAmount = int256(releaseTotalReal) - int256(releaseAmount);
    }

    function estimatePNL(IMarginPositionManager positionManager, uint256 positionId, uint256 closeMillionth)
        public
        view
        returns (int256 pnlAmount)
    {
        IPairPoolManager pairPoolManager = IPairPoolManager(IStatusBase(address(positionManager)).pairPoolManager());
        MarginPosition memory position = positionManager.getPosition(positionId);
        PoolStatus memory status = pairPoolManager.getStatus(position.poolId);
        pnlAmount = estimatePNL(pairPoolManager, status, position, closeMillionth);
    }

    function checkMinMarginLevel(
        IPairMarginManager poolManager,
        MarginParamsVo memory paramsVo,
        PoolStatus memory _status
    ) external view returns (bool valid) {
        MarginParams memory params = paramsVo.params;
        (uint256 reserve0, uint256 reserve1) =
            (_status.realReserve0 + _status.mirrorReserve0, _status.realReserve1 + _status.mirrorReserve1);
        (uint256 reserveBorrow, uint256 reserveMargin) =
            params.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 debtAmount;
        if (params.leverage > 0) {
            debtAmount = reserveMargin * params.borrowAmount / reserveBorrow;
        } else {
            (debtAmount,,) = poolManager.marginFees().getAmountOut(
                address(poolManager), _status, params.marginForOne, params.borrowAmount
            );
        }
        valid = params.marginAmount + paramsVo.marginTotal >= debtAmount.mulDivMillion(minMarginLevel);
    }

    function updatePosition(IMarginPositionManager positionManager, MarginPosition memory _position)
        external
        view
        returns (MarginPosition memory)
    {
        IPairPoolManager pairPoolManager = IPairPoolManager(IStatusBase(address(positionManager)).pairPoolManager());
        if (_position.rateCumulativeLast > 0) {
            uint256 rateLast = pairPoolManager.marginFees().getBorrowRateCumulativeLast(
                address(pairPoolManager), _position.poolId, _position.marginForOne
            );
            _position.borrowAmount = _position.borrowAmount.increaseInterestCeil(_position.rateCumulativeLast, rateLast);
            _position.rateCumulativeLast = rateLast;
            PoolStatus memory _status = pairPoolManager.getStatus(_position.poolId);
            Currency marginCurrency = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
            _position.marginAmount = pairPoolManager.lendingPoolManager().computeRealAmount(
                _position.poolId, marginCurrency, _position.marginAmount
            ).toUint112();
            _position.marginTotal = pairPoolManager.lendingPoolManager().computeRealAmount(
                _position.poolId, marginCurrency, _position.marginTotal
            ).toUint112();
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
            _position[i].position = positionManager.getPosition(positionIds[i]);
            _position[i].pnl = estimatePNL(positionManager, positionIds[i], PerLibrary.ONE_MILLION);
        }
    }

    /// @inheritdoc IMarginChecker
    function getMarginTotal(
        address _poolManager,
        PoolId poolId,
        bool marginForOne,
        uint24 leverage,
        uint256 marginAmount
    ) external view returns (uint256 marginWithoutFee, uint256 borrowAmount) {
        IPairPoolManager poolManager = IPairPoolManager(_poolManager);
        (, uint24 marginFee) = poolManager.marginFees().getPoolFees(address(poolManager), poolId);
        uint256 marginTotal = marginAmount * leverage;
        borrowAmount = poolManager.getAmountIn(poolId, marginForOne, marginTotal);
        marginWithoutFee = marginFee.deductFrom(marginTotal);
    }

    function getBorrowMax(address _poolManager, PoolId poolId, bool marginForOne, uint256 marginAmount)
        external
        view
        returns (uint256 marginAmountIn, uint256 borrowMax)
    {
        (uint256 reserveBorrow, uint256 reserveMargin) = getReserves(_poolManager, poolId, marginForOne);
        marginAmountIn = marginAmount.mulMillionDiv(minMarginLevel);
        borrowMax = Math.mulDiv(marginAmountIn, reserveBorrow, reserveMargin);
    }

    /// @inheritdoc IMarginChecker
    function getMarginMax(address _poolManager, PoolId poolId, bool marginForOne, uint24 leverage)
        external
        view
        returns (uint256 marginMax, uint256 borrowAmount)
    {
        IPairPoolManager poolManager = IPairPoolManager(_poolManager);
        PoolStatus memory status = poolManager.getStatus(poolId);

        if (leverage > 0) {
            (uint256 marginReserve0, uint256 marginReserve1, uint256 incrementMaxMirror0, uint256 incrementMaxMirror1) =
                poolManager.marginLiquidity().getMarginReserves(address(poolManager), poolId, status);
            uint256 borrowMaxAmount = marginForOne ? incrementMaxMirror0 : incrementMaxMirror1;
            uint256 marginMaxTotal = (marginForOne ? marginReserve1 : marginReserve0);
            if (marginMaxTotal > 1000 && borrowMaxAmount > 1000) {
                borrowMaxAmount -= 1000;
                uint256 marginBorrowMax = poolManager.getAmountOut(poolId, marginForOne, borrowMaxAmount);
                if (marginMaxTotal > marginBorrowMax) {
                    marginMaxTotal = marginBorrowMax;
                }
                {
                    uint256 marginMaxReserve = (marginForOne ? status.reserve1() : status.reserve0());
                    uint256 part = leverageThousandths[leverage - 1];
                    marginMaxReserve = Math.mulDiv(marginMaxReserve, part, 1000);
                    marginMaxTotal = Math.min(marginMaxTotal, marginMaxReserve);
                }
                borrowAmount = poolManager.getAmountIn(poolId, marginForOne, marginMaxTotal);
            }
            marginMax = marginMaxTotal / leverage;
        } else {
            (uint256 interestReserve0, uint256 interestReserve1) =
                poolManager.marginLiquidity().getInterestReserves(address(poolManager), poolId, status);
            uint256 borrowMaxAmount = (marginForOne ? interestReserve0 : interestReserve1);
            uint256 flowMaxAmount = (marginForOne ? status.realReserve0 : status.realReserve1) * 20 / 100;
            borrowMaxAmount = Math.min(borrowMaxAmount, flowMaxAmount);
            if (borrowMaxAmount > 1000) {
                borrowAmount = borrowMaxAmount - 1000;
            } else {
                borrowAmount = 0;
            }
            if (borrowAmount > 0) {
                (uint256 reserve0, uint256 reserve1) = (status.reserve0(), status.reserve1());
                (uint256 reserveBorrow, uint256 reserveMargin) =
                    marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
                marginMax = Math.mulDiv(reserveMargin, borrowAmount, reserveBorrow);
            }
        }
    }

    /// @inheritdoc IMarginChecker
    function getMaxDecrease(address _poolManager, PoolStatus memory _status, MarginPosition memory _position)
        public
        view
        returns (uint256 maxAmount)
    {
        IPairPoolManager poolManager = IPairPoolManager(_poolManager);
        (uint256 reserveBorrow, uint256 reserveMargin) =
            getReserves(_poolManager, _position.poolId, _position.marginForOne);
        uint256 debtAmount;
        if (_position.marginTotal > 0) {
            debtAmount = Math.mulDiv(reserveMargin, _position.borrowAmount, reserveBorrow);
        } else {
            (debtAmount,,) = poolManager.marginFees().getAmountOut(
                address(poolManager), _status, _position.marginForOne, _position.borrowAmount
            );
        }
        uint256 liquidatedAmount = debtAmount.mulDivMillion(liquidationMarginLevel);
        Currency marginCurrency = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        uint256 assetAmount = poolManager.lendingPoolManager().computeRealAmount(
            _position.poolId, marginCurrency, _position.marginAmount + _position.marginTotal
        );
        if (liquidatedAmount < assetAmount) {
            maxAmount = Math.mulDiv(assetAmount - liquidatedAmount, 800, 1000);
        }
        maxAmount = Math.min(uint256(_position.marginAmount), maxAmount);
    }

    function getMaxDecrease(address positionManager, uint256 positionId) external view returns (uint256 maxAmount) {
        IMarginPositionManager manager = IMarginPositionManager(positionManager);
        MarginPosition memory _position = manager.getPosition(positionId);
        address _poolManager = IStatusBase(positionManager).pairPoolManager();
        IPairPoolManager poolManager = IPairPoolManager(_poolManager);
        PoolStatus memory _status = poolManager.getStatus(_position.poolId);
        maxAmount = getMaxDecrease(_poolManager, _status, _position);
    }

    /// @inheritdoc IMarginChecker
    function getOracleReserves(address poolManager, PoolId poolId) public view returns (uint224 reserves) {
        address marginOracle = IPairPoolManager(poolManager).statusManager().marginOracle();
        if (marginOracle == address(0)) {
            reserves = 0;
        } else {
            (reserves,) = IMarginOracleReader(marginOracle).observeNow(IPairPoolManager(poolManager), poolId);
        }
    }

    /// @inheritdoc IMarginChecker
    function getReserves(address _poolManager, PoolId poolId, bool marginForOne)
        public
        view
        returns (uint256 reserveBorrow, uint256 reserveMargin)
    {
        IPairPoolManager poolManager = IPairPoolManager(_poolManager);
        uint224 oracleReserves = getOracleReserves(address(poolManager), poolId);
        if (oracleReserves == 0) {
            (uint256 reserve0, uint256 reserve1) = poolManager.getReserves(poolId);
            (reserveBorrow, reserveMargin) = marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        } else {
            (reserveBorrow, reserveMargin) = marginForOne
                ? (oracleReserves.getReverse0(), oracleReserves.getReverse1())
                : (oracleReserves.getReverse1(), oracleReserves.getReverse0());
        }
    }

    function _getReservesX224(PoolStatus memory status) internal pure returns (uint224 reserves) {
        reserves = (uint224(status.realReserve0 + status.mirrorReserve0) << 112)
            + uint224(status.realReserve1 + status.mirrorReserve1);
    }

    function _getOracleReserves(address poolManager, PoolStatus memory _status)
        internal
        view
        returns (uint224 reserves)
    {
        address marginOracle = IPairPoolManager(poolManager).statusManager().marginOracle();
        if (marginOracle == address(0)) {
            reserves = 0;
        } else {
            (reserves,) = IMarginOracleReader(marginOracle).observeNow(IPairPoolManager(poolManager), _status);
        }
    }

    function getLiquidateStatus(address pairPoolManager, PoolStatus memory _status, bool marginForOne)
        external
        view
        returns (LiquidateStatus memory liquidateStatus)
    {
        liquidateStatus.poolId = _status.key.toId();
        liquidateStatus.marginForOne = marginForOne;
        (liquidateStatus.borrowCurrency, liquidateStatus.marginCurrency) = marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        liquidateStatus.statusReserves = _getReservesX224(_status);
        liquidateStatus.oracleReserves = _getOracleReserves(pairPoolManager, _status);
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
        PoolStatus memory _status = pairPoolManager.getStatus(_position.poolId);
        return checkLiquidate(pairPoolManager, _status, _position);
    }

    /// @inheritdoc IMarginChecker
    function checkLiquidate(IPairMarginManager poolManager, PoolStatus memory _status, MarginPosition memory _position)
        public
        view
        returns (bool liquidated, uint256 borrowAmount)
    {
        if (_position.borrowAmount > 0) {
            borrowAmount = uint256(_position.borrowAmount);
            if (_position.rateCumulativeLast > 0) {
                uint256 rateLast = _position.marginForOne ? _status.rate0CumulativeLast : _status.rate1CumulativeLast;
                borrowAmount = _position.borrowAmount.increaseInterestCeil(_position.rateCumulativeLast, rateLast);
            }
            (uint256 reserveBorrow, uint256 reserveMargin) =
                getReserves(address(poolManager), _position.poolId, _position.marginForOne);
            uint256 debtAmount;
            if (_position.marginTotal > 0) {
                debtAmount = Math.mulDiv(reserveMargin, _position.borrowAmount, reserveBorrow);
            } else {
                (debtAmount,,) = poolManager.marginFees().getAmountOut(
                    address(poolManager), _status, _position.marginForOne, _position.borrowAmount
                );
            }
            uint256 liquidatedAmount = debtAmount.mulDivMillion(liquidationMarginLevel);
            Currency marginCurrency = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
            uint256 assetAmount = poolManager.lendingPoolManager().computeRealAmount(
                _position.poolId, marginCurrency, _position.marginAmount + _position.marginTotal
            );
            liquidated = assetAmount < liquidatedAmount;
        }
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
    function checkLiquidate(
        IPairMarginManager poolManager,
        LiquidateStatus memory _liqStatus,
        MarginPosition[] memory inPositions
    ) external view returns (bool[] memory liquidatedList, uint256[] memory borrowAmountList) {
        (uint256 reserveBorrow, uint256 reserveMargin) =
            getReserves(address(poolManager), _liqStatus.poolId, _liqStatus.marginForOne);
        PoolStatus memory _status = poolManager.getStatus(_liqStatus.poolId);
        uint256 rateLast = _liqStatus.marginForOne ? _status.rate0CumulativeLast : _status.rate1CumulativeLast;
        liquidatedList = new bool[](inPositions.length);
        borrowAmountList = new uint256[](inPositions.length);
        for (uint256 i = 0; i < inPositions.length; i++) {
            MarginPosition memory _position = inPositions[i];
            if (
                PoolId.unwrap(_position.poolId) == PoolId.unwrap(_liqStatus.poolId)
                    && _position.marginForOne == _liqStatus.marginForOne
            ) {
                if (_position.borrowAmount > 0) {
                    uint256 borrowAmount = _position.borrowAmount;
                    uint256 assetAmount = poolManager.lendingPoolManager().computeRealAmount(
                        _position.poolId, _liqStatus.marginCurrency, _position.marginAmount + _position.marginTotal
                    );
                    if (_position.rateCumulativeLast > 0) {
                        borrowAmount =
                            _position.borrowAmount.increaseInterestCeil(_position.rateCumulativeLast, rateLast);
                    }
                    uint256 debtAmount;
                    if (_position.marginTotal > 0) {
                        debtAmount = Math.mulDiv(reserveMargin, _position.borrowAmount, reserveBorrow);
                    } else {
                        (debtAmount,,) = poolManager.marginFees().getAmountOut(
                            address(poolManager), _status, _position.marginForOne, _position.borrowAmount
                        );
                    }
                    uint256 liquidatedAmount = debtAmount.mulDivMillion(liquidationMarginLevel);
                    liquidatedList[i] = assetAmount < liquidatedAmount;
                    borrowAmountList[i] = borrowAmount;
                }
            }
        }
    }
}
