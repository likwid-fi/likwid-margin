// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {TimeLibrary} from "./libraries/TimeLibrary.sol";
import {TruncatedOracle, PriceMath} from "./libraries/TruncatedOracle.sol";
import {RateStatus} from "./types/RateStatus.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {MarginParams} from "./types/MarginParams.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IMarginFees} from "./interfaces/IMarginFees.sol";
import {IMarginOracleReader} from "./interfaces/IMarginOracleReader.sol";

contract MarginFees is IMarginFees, Owned {
    using SafeCast for uint256;
    using UQ112x112 for *;
    using PriceMath for uint224;
    using PoolIdLibrary for PoolKey;
    using TimeLibrary for uint32;
    using FeeLibrary for uint24;
    using PerLibrary for uint256;
    using PoolStatusLibrary for PoolStatus;

    uint24 public marginFee = 3000; // 0.3%
    uint24 public protocolFee = 50000; // 5%
    uint24 public dynamicFeeMinDegree = 100000; // 10%

    address public feeTo;

    RateStatus public rateStatus;

    constructor(address initialOwner) Owned(initialOwner) {
        rateStatus = RateStatus({
            rateBase: 50000,
            useMiddleLevel: 400000,
            useHighLevel: 800000,
            mLow: 10,
            mMiddle: 100,
            mHigh: 10000
        });
        feeTo = initialOwner;
    }

    /// @inheritdoc IMarginFees
    function getPoolFees(address _poolManager, PoolId poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut)
        external
        view
        returns (uint24 _fee, uint24 _marginFee)
    {
        IPairPoolManager poolManager = IPairPoolManager(_poolManager);
        PoolStatus memory status = poolManager.getStatus(poolId);
        _fee = dynamicFee(_poolManager, status, zeroForOne, amountIn, amountOut);
        _marginFee = status.marginFee == 0 ? marginFee : status.marginFee;
    }

    function differencePrice(uint256 price, uint256 lastPrice) internal pure returns (uint256 priceDiff) {
        priceDiff = price > lastPrice ? price - lastPrice : lastPrice - price;
    }

    function _getPriceDegree(
        uint224 oracleReserves,
        PoolStatus memory status,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    ) internal pure returns (uint256 degree) {
        if (oracleReserves > 0) {
            uint256 lastPrice0X112 = oracleReserves.getPrice0X112();
            uint256 lastPrice1X112 = oracleReserves.getPrice1X112();
            (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
            if (amountIn > 0) {
                amountOut = status.getAmountOut(zeroForOne, amountIn);
            } else if (amountOut > 0) {
                amountIn = status.getAmountIn(zeroForOne, amountOut);
            }
            if (zeroForOne) {
                _reserve1 -= amountOut;
                _reserve0 += amountIn;
            } else {
                _reserve0 -= amountOut;
                _reserve1 += amountIn;
            }
            uint224 price0X112 = UQ112x112.encode(_reserve1.toUint112()).div(_reserve0.toUint112());
            uint224 price1X112 = UQ112x112.encode(_reserve0.toUint112()).div(_reserve1.toUint112());
            uint256 degree0 = differencePrice(price0X112, lastPrice0X112).mulMillionDiv(lastPrice0X112);
            uint256 degree1 = differencePrice(price1X112, lastPrice1X112).mulMillionDiv(lastPrice1X112);
            degree = Math.max(degree0, degree1);
        }
    }

    /// @inheritdoc IMarginFees
    function dynamicFee(
        address _poolManager,
        PoolStatus memory status,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    ) public view returns (uint24 _fee) {
        _fee = status.key.fee;
        IMarginOracleReader oracleReader = IPairPoolManager(_poolManager).marginOracleReader();
        if (address(oracleReader) != address(0)) {
            (uint224 oracleReserves,) = oracleReader.observeNow(IPairPoolManager(_poolManager), status);
            if (oracleReserves > 0) {
                uint256 degree = _getPriceDegree(oracleReserves, status, zeroForOne, amountIn, amountOut);
                if (degree > PerLibrary.ONE_MILLION) {
                    _fee = uint24(PerLibrary.ONE_MILLION) - 10000;
                } else if (degree > dynamicFeeMinDegree) {
                    uint256 dFee = Math.mulDiv((degree * 10) ** 3, _fee, PerLibrary.ONE_MILLION ** 3);
                    if (dFee >= PerLibrary.ONE_MILLION) {
                        _fee = uint24(PerLibrary.ONE_MILLION) - 10000;
                    } else {
                        _fee = uint24(dFee);
                    }
                }
            }
        }
    }

    function _getReserves(PoolStatus memory status) internal pure returns (uint256 _reserve0, uint256 _reserve1) {
        _reserve0 = status.realReserve0 + status.mirrorReserve0;
        _reserve1 = status.realReserve1 + status.mirrorReserve1;
    }

    function computeDiff(address pairPoolManager, PoolStatus memory status, bool marginForOne, int256 diff)
        external
        view
        returns (int256 interest0, int256 interest1, int256 lendingInterest)
    {
        if (diff == 0) {
            return (interest0, interest1, lendingInterest);
        }
        uint256 diffUint = diff > 0 ? uint256(diff) : uint256(-diff);
        (uint256 interestReserve0, uint256 interestReserve1) = IPairPoolManager(pairPoolManager).marginLiquidity()
            .getInterestReserves(pairPoolManager, status.key.toId(), status);
        uint256 pairReserve = marginForOne ? interestReserve0 : interestReserve1;
        uint256 lendingReserve = marginForOne ? status.lendingReserve0() : status.lendingReserve1();
        uint256 lendingDiff = Math.mulDiv(diffUint, lendingReserve, pairReserve + lendingReserve);
        uint256 pairDiff = diffUint - lendingDiff;
        if (diff > 0) {
            if (marginForOne) {
                interest0 = pairDiff.toInt256();
            } else {
                interest1 = pairDiff.toInt256();
            }
            lendingInterest = lendingDiff.toInt256();
        } else {
            if (marginForOne) {
                interest0 = -(pairDiff.toInt256());
            } else {
                interest1 = -(pairDiff.toInt256());
            }
            lendingInterest = -(lendingDiff.toInt256());
        }
    }

    function getMarginBorrow(PoolStatus memory status, MarginParams memory params)
        external
        view
        returns (uint256 marginWithoutFee, uint256 marginFeeAmount, uint256 borrowAmount)
    {
        uint256 marginReserves;
        uint256 incrementMaxMirror;
        {
            (uint256 marginReserve0, uint256 marginReserve1, uint256 incrementMaxMirror0, uint256 incrementMaxMirror1) =
                IPairPoolManager(msg.sender).marginLiquidity().getMarginReserves(msg.sender, params.poolId, status);
            marginReserves = params.marginForOne ? marginReserve1 : marginReserve0;
            incrementMaxMirror = params.marginForOne ? incrementMaxMirror0 : incrementMaxMirror1;
        }
        {
            uint256 marginTotal = params.marginAmount * params.leverage;
            require(marginReserves >= marginTotal, "MARGIN_NOT_ENOUGH");
            if (params.leverage > 0) {
                (borrowAmount,,) =
                    IPairPoolManager(msg.sender).statusManager().getAmountIn(status, params.marginForOne, marginTotal);
                require(incrementMaxMirror >= borrowAmount, "MIRROR_TOO_MUCH");
            }
            uint24 _marginFeeRate = status.marginFee == 0 ? marginFee : status.marginFee;
            (marginWithoutFee, marginFeeAmount) = _marginFeeRate.deduct(marginTotal);
        }
    }

    function getBorrowMaxAmount(
        PoolStatus memory status,
        uint256 marginAmount,
        bool marginForOne,
        uint256 minMarginLevel
    ) external view returns (uint256 borrowMaxAmount) {
        {
            (borrowMaxAmount,,) =
                IPairPoolManager(msg.sender).statusManager().getAmountOut(status, !marginForOne, marginAmount);
            uint256 flowMaxAmount = (marginForOne ? status.realReserve0 : status.realReserve1) * 20 / 100;
            borrowMaxAmount = borrowMaxAmount.mulMillionDiv(minMarginLevel);
            borrowMaxAmount = Math.min(borrowMaxAmount, flowMaxAmount);
        }
        {
            (uint256 interestReserve0, uint256 interestReserve1) = IPairPoolManager(msg.sender).marginLiquidity()
                .getInterestReserves(msg.sender, status.key.toId(), status);
            uint256 borrowReserves = (marginForOne ? interestReserve0 : interestReserve1);
            require(borrowReserves >= borrowMaxAmount, "MIRROR_TOO_MUCH");
        }
    }

    /// @inheritdoc IMarginFees
    function getBorrowRateByReserves(uint256 realReserve, uint256 mirrorReserve) public view returns (uint256 rate) {
        rate = rateStatus.rateBase;
        if (mirrorReserve == 0) {
            return rate;
        }
        uint256 useLevel = Math.mulDiv(mirrorReserve, PerLibrary.ONE_MILLION, (mirrorReserve + realReserve));
        if (useLevel >= rateStatus.useHighLevel) {
            rate += uint256(useLevel - rateStatus.useHighLevel) * rateStatus.mHigh;
            useLevel = rateStatus.useHighLevel;
        }
        if (useLevel >= rateStatus.useMiddleLevel) {
            rate += uint256(useLevel - rateStatus.useMiddleLevel) * rateStatus.mMiddle;
            useLevel = rateStatus.useMiddleLevel;
        }
        return rate + useLevel * rateStatus.mLow;
    }

    function getBorrowRateCumulativeLast(PoolStatus memory status)
        public
        view
        returns (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast)
    {
        uint256 timeElapsed = status.blockTimestampLast.getTimeElapsedMicrosecond();
        uint256 rate0 = getBorrowRateByReserves(status.totalRealReserve0(), status.totalMirrorReserve0());
        uint256 rate0LastYear = PerLibrary.TRILLION_YEAR_SECONDS + rate0 * timeElapsed;
        rate0CumulativeLast = Math.mulDiv(status.rate0CumulativeLast, rate0LastYear, PerLibrary.TRILLION_YEAR_SECONDS);
        uint256 rate1 = getBorrowRateByReserves(status.totalRealReserve1(), status.totalMirrorReserve1());
        uint256 rate1LastYear = PerLibrary.TRILLION_YEAR_SECONDS + rate1 * timeElapsed;
        rate1CumulativeLast = Math.mulDiv(status.rate1CumulativeLast, rate1LastYear, PerLibrary.TRILLION_YEAR_SECONDS);
    }

    function getBorrowRateCumulativeLast(address pool, PoolId poolId, bool marginForOne)
        external
        view
        returns (uint256)
    {
        PoolStatus memory status = IPairPoolManager(pool).getStatus(poolId);
        return marginForOne ? status.rate0CumulativeLast : status.rate1CumulativeLast;
    }

    /// @inheritdoc IMarginFees
    function getBorrowRate(PoolStatus memory status, bool marginForOne) public view returns (uint256) {
        uint256 realReserve = marginForOne ? status.totalRealReserve0() : status.totalRealReserve1();
        uint256 mirrorReserve = marginForOne ? status.totalMirrorReserve0() : status.totalMirrorReserve1();
        return getBorrowRateByReserves(realReserve, mirrorReserve);
    }

    /// @inheritdoc IMarginFees
    function getBorrowRate(address pool, PoolId poolId, bool marginForOne) external view returns (uint256) {
        PoolStatus memory status = IPairPoolManager(pool).getStatus(poolId);
        return getBorrowRate(status, marginForOne);
    }

    /// @inheritdoc IMarginFees
    function getProtocolFeeAmount(uint256 totalFee) external view returns (uint256 feeAmount) {
        feeAmount = protocolFee.part(totalFee);
    }

    // ******************** OWNER CALL ********************

    function setFeeTo(address _feeTo) external onlyOwner {
        feeTo = _feeTo;
    }

    function setProtocolFee(uint24 _protocolFee) external onlyOwner {
        protocolFee = _protocolFee;
    }

    function setRateStatus(RateStatus calldata _status) external onlyOwner {
        rateStatus = _status;
    }

    function setDynamicFeeMinDegree(uint24 _dynamicFeeMinDegree) external onlyOwner {
        dynamicFeeMinDegree = _dynamicFeeMinDegree;
    }

    /// @inheritdoc IMarginFees
    function collectProtocolFees(address poolManager, address recipient, Currency currency, uint256 amount)
        external
        onlyOwner
        returns (uint256)
    {
        return IPairPoolManager(poolManager).collectProtocolFees(recipient, currency, amount);
    }
}
