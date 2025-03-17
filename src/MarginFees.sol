// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
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
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IMarginFees} from "./interfaces/IMarginFees.sol";
import {IMarginOracleReader} from "./interfaces/IMarginOracleReader.sol";

import {console} from "forge-std/console.sol";

contract MarginFees is IMarginFees, Owned {
    using UQ112x112 for *;
    using PriceMath for uint224;
    using PoolIdLibrary for PoolKey;
    using TimeLibrary for uint32;
    using FeeLibrary for uint24;
    using PerLibrary for uint256;
    using PoolStatusLibrary for PoolStatus;

    uint24 public marginFee = 3000; // 0.3%
    uint24 public protocolFee = 50000; // 5%
    uint24 public dynamicFeeUnit = 10;
    uint24 public dynamicFeeMinDegree = 30000; // 3%

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
    function getPoolFees(address _poolManager, PoolId poolId) external view returns (uint24 _fee, uint24 _marginFee) {
        IPairPoolManager poolManager = IPairPoolManager(_poolManager);
        PoolStatus memory status = poolManager.getStatus(poolId);
        _fee = dynamicFee(_poolManager, status);
        _marginFee = status.marginFee == 0 ? marginFee : status.marginFee;
    }

    function differencePrice(uint256 price, uint256 lastPrice) internal pure returns (uint256 priceDiff) {
        priceDiff = price > lastPrice ? price - lastPrice : lastPrice - price;
    }

    function _getPriceDegree(uint224 oracleReserves, PoolStatus memory status) internal pure returns (uint256 degree) {
        if (oracleReserves > 0) {
            uint256 lastPrice0X112 = oracleReserves.getPrice0X112();
            uint256 lastPrice1X112 = oracleReserves.getPrice1X112();
            (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
            uint224 price0X112 = UQ112x112.encode(_reserve1.toUint112()).div(_reserve0.toUint112());
            uint224 price1X112 = UQ112x112.encode(_reserve0.toUint112()).div(_reserve1.toUint112());
            uint256 degree0 = differencePrice(price0X112, lastPrice0X112).mulMillionDiv(lastPrice0X112);
            uint256 degree1 = differencePrice(price1X112, lastPrice1X112).mulMillionDiv(lastPrice1X112);
            degree = Math.max(degree0, degree1);
        }
    }

    /// @inheritdoc IMarginFees
    function dynamicFee(address _poolManager, PoolStatus memory status) public view returns (uint24 _fee) {
        uint256 timeElapsed = status.marginTimestampLast.getTimeElapsed();
        _fee = status.key.fee;
        IMarginOracleReader oracleReader = IPairPoolManager(_poolManager).marginOracleReader();
        if (address(oracleReader) != address(0)) {
            (uint224 oracleReserves,) = oracleReader.observeNow(IPairPoolManager(_poolManager), status.key.toId());
            if (oracleReserves > 0) {
                uint256 degree = _getPriceDegree(oracleReserves, status);
                if (degree > dynamicFeeMinDegree) {
                    uint256 dFee = degree.mulDivMillion(uint256(dynamicFeeUnit) * _fee) + _fee;
                    if (dFee >= PerLibrary.ONE_MILLION) {
                        _fee = uint24(PerLibrary.ONE_MILLION) - 1;
                    } else {
                        _fee = uint24(dFee);
                    }
                }
            }
        }
        if (timeElapsed == 0) {
            uint24 oneBlockFee = 20 * status.key.fee;
            if (oneBlockFee > _fee) {
                _fee = oneBlockFee;
            }
        }
    }

    // given an input amount of an asset and pair reserve, returns the maximum output amount of the other asset
    function getAmountOut(address _poolManager, PoolStatus memory status, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint24 fee, uint256 feeAmount)
    {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        require(reserveIn > 0 && reserveOut > 0, " INSUFFICIENT_LIQUIDITY");
        fee = dynamicFee(_poolManager, status);
        uint256 amountInWithoutFee;
        (amountInWithoutFee, feeAmount) = fee.deduct(amountIn);
        uint256 numerator = amountInWithoutFee * reserveOut;
        uint256 denominator = reserveIn + amountInWithoutFee;
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserve, returns a required input amount of the other asset
    function getAmountIn(address _poolManager, PoolStatus memory status, bool zeroForOne, uint256 amountOut)
        external
        view
        returns (uint256 amountIn, uint24 fee, uint256 feeAmount)
    {
        require(amountOut > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        require(amountOut < reserveOut, "OUTPUT_AMOUNT_OVERFLOW");
        fee = dynamicFee(_poolManager, status);
        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = (reserveOut - amountOut);
        uint256 amountInWithoutFee = (numerator / denominator) + 1;
        (amountIn, feeAmount) = fee.attach(amountInWithoutFee);
    }

    function _getReserves(PoolStatus memory status) internal pure returns (uint256 _reserve0, uint256 _reserve1) {
        _reserve0 = status.realReserve0 + status.mirrorReserve0;
        _reserve1 = status.realReserve1 + status.mirrorReserve1;
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
        external
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

    /// @inheritdoc IMarginFees
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

    function setDynamicFeeUnit(uint24 _dynamicFeeUnit) external onlyOwner {
        dynamicFeeUnit = _dynamicFeeUnit;
    }

    /// @inheritdoc IMarginFees
    function collectProtocolFees(address pool, address recipient, Currency currency, uint256 amount)
        external
        onlyOwner
        returns (uint256)
    {
        return IPairPoolManager(pool).collectProtocolFees(recipient, currency, amount);
    }
}
