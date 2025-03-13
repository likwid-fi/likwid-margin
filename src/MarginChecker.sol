// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// Local
import {PoolStatus} from "./types/PoolStatus.sol";
import {MarginParams} from "./types/MarginParams.sol";
import {LiquidateStatus} from "./types/LiquidateStatus.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {MarginPosition, MarginPositionVo} from "./types/MarginPosition.sol";
import {BurnParams} from "./types/BurnParams.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IMarginChecker} from "./interfaces/IMarginChecker.sol";
import {IMarginOracleReader} from "./interfaces/IMarginOracleReader.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";

contract MarginChecker is IMarginChecker, Owned {
    using UQ112x112 for *;
    using PriceMath for uint224;
    using PerLibrary for uint256;
    using FeeLibrary for uint24;

    uint24 public liquidationMarginLevel = 1100000; // 110%
    uint24 public minMarginLevel = 1170000; // 117%
    uint256 public constant ONE_MILLION = 10 ** 6;
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
    function checkValidity(address, uint256, bytes calldata) external pure returns (bool) {
        return true;
    }

    function estimatePNL(
        IPairPoolManager pairPoolManager,
        PoolStatus memory _status,
        MarginPosition memory _position,
        uint256 closeMillionth
    ) external view returns (int256 pnlAmount) {
        if (_position.borrowAmount == 0) {
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

    function checkMinMarginLevel(IPairPoolManager poolManager, MarginParams memory params, PoolStatus memory _status)
        external
        view
        returns (bool valid)
    {
        (uint256 reserve0, uint256 reserve1) =
            (_status.realReserve0 + _status.mirrorReserve0, _status.realReserve1 + _status.mirrorReserve1);
        (uint256 reserveBorrow, uint256 reserveMargin) =
            params.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 debtAmount;
        if (params.leverage > 0) {
            debtAmount = reserveMargin * params.borrowAmount / reserveBorrow;
        } else {
            debtAmount = poolManager.getAmountOut(params.poolId, params.marginForOne, params.borrowAmount);
        }
        valid = params.marginAmount + params.marginTotal >= debtAmount.mulDivMillion(minMarginLevel);
    }

    /// @inheritdoc IMarginChecker
    function getMarginTotal(
        IPairPoolManager poolManager,
        PoolId poolId,
        bool marginForOne,
        uint24 leverage,
        uint256 marginAmount
    ) external view returns (uint256 marginWithoutFee, uint256 borrowAmount) {
        (, uint24 marginFee) = poolManager.marginFees().getPoolFees(address(poolManager), poolId);
        uint256 marginTotal = marginAmount * leverage;
        borrowAmount = poolManager.getAmountIn(poolId, marginForOne, marginTotal);
        marginWithoutFee = marginFee.deductFrom(marginTotal);
    }

    function getBorrowMax(IPairPoolManager poolManager, PoolId poolId, bool marginForOne, uint256 marginAmount)
        external
        view
        returns (uint256 marginAmountIn, uint256 borrowAmount)
    {
        (uint256 reserveBorrow, uint256 reserveMargin) = getReserves(poolManager, poolId, marginForOne);
        marginAmountIn = marginAmount.mulMillionDiv(minMarginLevel);
        borrowAmount = Math.mulDiv(marginAmountIn, reserveBorrow, reserveMargin);
    }

    /// @inheritdoc IMarginChecker
    function getMarginMax(IPairPoolManager poolManager, PoolId poolId, bool marginForOne, uint24 leverage)
        external
        view
        returns (uint256 marginMax, uint256 borrowAmount)
    {
        PoolStatus memory status = poolManager.getStatus(poolId);
        (uint256 marginReserve1, uint256 marginReserve0) =
            poolManager.marginLiquidity().getFlowReserves(address(poolManager), poolId, status);
        if (leverage > 0) {
            uint256 marginMaxTotal = (marginForOne ? marginReserve1 : marginReserve0);
            if (marginMaxTotal > 1000) {
                (uint256 reserve0, uint256 reserve1) = poolManager.getReserves(poolId);
                uint256 marginMaxReserve = (marginForOne ? reserve1 : reserve0);
                uint24 part = leverageThousandths[leverage - 1];
                marginMaxReserve = marginMaxReserve * part / 1000;
                marginMaxTotal = Math.min(marginMaxTotal, marginMaxReserve);
                marginMaxTotal -= 1000;
            }
            borrowAmount = poolManager.getAmountIn(poolId, marginForOne, marginMaxTotal);
            marginMax = marginMaxTotal / leverage;
        } else {
            uint256 borrowMaxAmount = (marginForOne ? marginReserve0 : marginReserve1);
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
    function getMaxDecrease(IPairPoolManager poolManager, PoolStatus memory _status, MarginPosition memory _position)
        public
        view
        returns (uint256 maxAmount)
    {
        (uint256 reserveBorrow, uint256 reserveMargin) =
            getReserves(poolManager, _position.poolId, _position.marginForOne);
        uint256 debtAmount;
        if (_position.marginTotal > 0) {
            debtAmount = Math.mulDiv(reserveMargin, _position.borrowAmount, reserveBorrow);
        } else {
            debtAmount = poolManager.getAmountOut(_position.poolId, _position.marginForOne, _position.borrowAmount);
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
        IPairPoolManager poolManager = IPairPoolManager(manager.getPairPool());
        PoolStatus memory _status = poolManager.getStatus(_position.poolId);
        maxAmount = getMaxDecrease(poolManager, _status, _position);
    }

    /// @inheritdoc IMarginChecker
    function getOracleReserves(IPairPoolManager poolManager, PoolId poolId) public view returns (uint224 reserves) {
        address marginOracle = poolManager.statusManager().marginOracle();
        if (marginOracle == address(0)) {
            reserves = 0;
        } else {
            (reserves,) = IMarginOracleReader(marginOracle).observeNow(poolManager, poolId);
        }
    }

    /// @inheritdoc IMarginChecker
    function getReserves(IPairPoolManager poolManager, PoolId poolId, bool marginForOne)
        public
        view
        returns (uint256 reserveBorrow, uint256 reserveMargin)
    {
        uint224 oracleReserves = getOracleReserves(poolManager, poolId);
        if (oracleReserves == 0) {
            (uint256 reserve0, uint256 reserve1) = poolManager.getReserves(poolId);
            (reserveBorrow, reserveMargin) = marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        } else {
            (reserveBorrow, reserveMargin) = marginForOne
                ? (oracleReserves.getReverse0(), oracleReserves.getReverse1())
                : (oracleReserves.getReverse1(), oracleReserves.getReverse0());
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
        PoolStatus memory _status = IPairPoolManager(positionManager.getPairPool()).getStatus(_position.poolId);
        return checkLiquidate(IPairPoolManager(positionManager.getPairPool()), _status, _position);
    }

    /// @inheritdoc IMarginChecker
    function checkLiquidate(IPairPoolManager poolManager, PoolStatus memory _status, MarginPosition memory _position)
        public
        view
        returns (bool liquidated, uint256 borrowAmount)
    {
        if (_position.borrowAmount > 0) {
            borrowAmount = uint256(_position.borrowAmount);
            if (_position.rateCumulativeLast > 0) {
                uint256 rateLast = poolManager.marginFees().getBorrowRateCumulativeLast(
                    address(poolManager), _position.poolId, _position.marginForOne
                );
                borrowAmount = _position.borrowAmount.increaseInterestCeil(_position.rateCumulativeLast, rateLast);
            }
            (uint256 reserveBorrow, uint256 reserveMargin) =
                getReserves(poolManager, _position.poolId, _position.marginForOne);
            uint256 debtAmount;
            if (_position.marginTotal > 0) {
                debtAmount = Math.mulDiv(reserveMargin, _position.borrowAmount, reserveBorrow);
            } else {
                debtAmount = poolManager.getAmountOut(_position.poolId, _position.marginForOne, _position.borrowAmount);
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
        IPairPoolManager poolManager,
        LiquidateStatus memory _liqStatus,
        MarginPosition[] memory inPositions
    ) external view returns (bool[] memory liquidatedList, uint256[] memory borrowAmountList) {
        (uint256 reserveBorrow, uint256 reserveMargin) =
            getReserves(poolManager, _liqStatus.poolId, _liqStatus.marginForOne);
        uint256 rateLast = poolManager.marginFees().getBorrowRateCumulativeLast(
            address(poolManager), _liqStatus.poolId, _liqStatus.marginForOne
        );
        bytes32 bytes32PoolId = PoolId.unwrap(_liqStatus.poolId);
        liquidatedList = new bool[](inPositions.length);
        borrowAmountList = new uint256[](inPositions.length);
        for (uint256 i = 0; i < inPositions.length; i++) {
            MarginPosition memory _position = inPositions[i];
            if (PoolId.unwrap(_position.poolId) == bytes32PoolId && _position.marginForOne == _liqStatus.marginForOne) {
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
                        debtAmount =
                            poolManager.getAmountOut(_position.poolId, _position.marginForOne, _position.borrowAmount);
                    }
                    uint256 liquidatedAmount = debtAmount.mulDivMillion(liquidationMarginLevel);
                    liquidatedList[i] = assetAmount < liquidatedAmount;
                    borrowAmountList[i] = borrowAmount;
                }
            }
        }
    }
}
