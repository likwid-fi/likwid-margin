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
import {RateStatus} from "./types/RateStatus.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {MarginParams} from "./types/MarginParams.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IMarginFees} from "./interfaces/IMarginFees.sol";

contract MarginFees is IMarginFees, Owned {
    using SafeCast for uint256;
    using UQ112x112 for *;
    using PoolIdLibrary for PoolKey;
    using TimeLibrary for uint32;
    using FeeLibrary for uint24;
    using PerLibrary for uint256;
    using PoolStatusLibrary for PoolStatus;

    uint24 public marginFee = 3000; // 0.3%
    uint24 public protocolSwapFee = 100000; // LP receive 90% of the SwapFee, while 10% goes to the treasury.
    uint24 public protocolMarginFee = 200000; // LP receive 80% of the MarginFee, while 20% goes to the treasury.
    uint24 public protocolInterestFee = 50000; // LP receive 95% of the Interest, while 5% goes to the treasury.

    address public feeTo;

    RateStatus public rateStatus;

    modifier onlyFeeTo() {
        require(msg.sender == feeTo, "UNAUTHORIZED");
        _;
    }

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
        _fee = dynamicFee(status, zeroForOne, amountIn, amountOut);
        _marginFee = status.marginFee == 0 ? marginFee : status.marginFee;
    }

    function differencePrice(uint256 price, uint256 lastPrice) internal pure returns (uint256 priceDiff) {
        priceDiff = price > lastPrice ? price - lastPrice : lastPrice - price;
    }

    function _getPriceDegree(PoolStatus memory status, bool zeroForOne, uint256 amountIn, uint256 amountOut)
        internal
        pure
        returns (uint256 degree)
    {
        if (status.truncatedReserve0 > 0 && status.truncatedReserve1 > 0) {
            uint256 lastPrice0X112 = UQ112x112.encode(status.truncatedReserve1).div(status.truncatedReserve0);
            uint256 lastPrice1X112 = UQ112x112.encode(status.truncatedReserve0).div(status.truncatedReserve1);
            (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
            if (_reserve0 == 0 || _reserve1 == 0) {
                return degree;
            }
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
    function dynamicFee(PoolStatus memory status, bool zeroForOne, uint256 amountIn, uint256 amountOut)
        public
        pure
        returns (uint24 _fee)
    {
        _fee = status.key.fee;
        uint256 degree = _getPriceDegree(status, zeroForOne, amountIn, amountOut);
        if (degree > PerLibrary.ONE_MILLION) {
            _fee = uint24(PerLibrary.ONE_MILLION) - 10000;
        } else if (degree > 100000) {
            uint256 dFee = Math.mulDiv((degree * 10) ** 3, _fee, PerLibrary.ONE_MILLION ** 3);
            if (dFee >= PerLibrary.ONE_MILLION) {
                _fee = uint24(PerLibrary.ONE_MILLION) - 10000;
            } else {
                _fee = uint24(dFee);
            }
        }
    }

    function _getReserves(PoolStatus memory status) internal pure returns (uint256 _reserve0, uint256 _reserve1) {
        _reserve0 = status.realReserve0 + status.mirrorReserve0;
        _reserve1 = status.realReserve1 + status.mirrorReserve1;
    }

    function getAmountOut(address pairPoolManager, PoolId poolId, bool zeroForOne, uint256 amountIn, bool useDynamicFee)
        external
        view
        returns (uint256 amountOut, uint24 fee, uint256 feeAmount)
    {
        PoolStatus memory status = IPairPoolManager(pairPoolManager).getStatus(poolId);
        if (useDynamicFee) {
            return IPairPoolManager(pairPoolManager).statusManager().getAmountOut(status, zeroForOne, amountIn);
        }
        (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        uint256 numerator = amountIn * reserveOut;
        uint256 denominator = reserveIn + amountIn;
        amountOut = numerator / denominator;
    }

    function getAmountIn(address pairPoolManager, PoolId poolId, bool zeroForOne, uint256 amountOut, bool useDynamicFee)
        external
        view
        returns (uint256 amountIn, uint24 fee, uint256 feeAmount)
    {
        PoolStatus memory status = IPairPoolManager(pairPoolManager).getStatus(poolId);
        if (useDynamicFee) {
            return IPairPoolManager(pairPoolManager).statusManager().getAmountIn(status, zeroForOne, amountOut);
        }
        (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = (reserveOut - amountOut);
        amountIn = (numerator / denominator) + 1;
    }

    /// @inheritdoc IMarginFees
    function getBorrowRateByReserves(uint256 borrowReserve, uint256 mirrorReserve) public view returns (uint256 rate) {
        rate = rateStatus.rateBase;
        if (mirrorReserve == 0) {
            return rate;
        }
        uint256 useLevel = Math.mulDiv(mirrorReserve, PerLibrary.ONE_MILLION, borrowReserve);
        if (useLevel >= rateStatus.useHighLevel) {
            rate += uint256(useLevel - rateStatus.useHighLevel) * rateStatus.mHigh / 100;
            useLevel = rateStatus.useHighLevel;
        }
        if (useLevel >= rateStatus.useMiddleLevel) {
            rate += uint256(useLevel - rateStatus.useMiddleLevel) * rateStatus.mMiddle / 100;
            useLevel = rateStatus.useMiddleLevel;
        }
        return rate + useLevel * rateStatus.mLow / 100;
    }

    function getBorrowRateCumulativeLast(uint256 interestReserve0, uint256 interestReserve1, PoolStatus memory status)
        public
        view
        returns (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast)
    {
        uint256 timeElapsed = status.blockTimestampLast.getTimeElapsedMicrosecond();
        uint256 rate0 =
            getBorrowRateByReserves(interestReserve0 + status.lendingReserve0(), status.totalMirrorReserve0());
        uint256 rate0LastYear = PerLibrary.TRILLION_YEAR_SECONDS + rate0 * timeElapsed;
        rate0CumulativeLast = Math.mulDiv(status.rate0CumulativeLast, rate0LastYear, PerLibrary.TRILLION_YEAR_SECONDS);
        uint256 rate1 =
            getBorrowRateByReserves(interestReserve1 + status.lendingReserve1(), status.totalMirrorReserve1());
        uint256 rate1LastYear = PerLibrary.TRILLION_YEAR_SECONDS + rate1 * timeElapsed;
        rate1CumulativeLast = Math.mulDiv(status.rate1CumulativeLast, rate1LastYear, PerLibrary.TRILLION_YEAR_SECONDS);
    }

    function getBorrowRateCumulativeLast(address pairPoolManager, PoolId poolId, bool marginForOne)
        external
        view
        returns (uint256)
    {
        PoolStatus memory status = IPairPoolManager(pairPoolManager).getStatus(poolId);
        return marginForOne ? status.rate0CumulativeLast : status.rate1CumulativeLast;
    }

    /// @inheritdoc IMarginFees
    function getBorrowRate(address pairPoolManager, PoolStatus memory status, bool marginForOne)
        public
        view
        returns (uint256)
    {
        (uint256 interestReserve0, uint256 interestReserve1) = IPairPoolManager(pairPoolManager).marginLiquidity()
            .getInterestReserves(pairPoolManager, status.key.toId(), status);
        uint256 interestReserve =
            marginForOne ? interestReserve0 + status.lendingReserve0() : interestReserve1 + status.lendingReserve1();
        uint256 mirrorReserve = marginForOne ? status.totalMirrorReserve0() : status.totalMirrorReserve1();
        return getBorrowRateByReserves(interestReserve, mirrorReserve);
    }

    /// @inheritdoc IMarginFees
    function getBorrowRate(address pairPoolManager, PoolId poolId, bool marginForOne) external view returns (uint256) {
        PoolStatus memory status = IPairPoolManager(pairPoolManager).getStatus(poolId);
        return getBorrowRate(pairPoolManager, status, marginForOne);
    }

    function getUtilizationReserves(address pairPoolManager, PoolId poolId)
        external
        view
        returns (uint256 suppliedReserve0, uint256 suppliedReserve1, uint256 borrowedReserve0, uint256 borrowedReserve1)
    {
        PoolStatus memory status = IPairPoolManager(pairPoolManager).getStatus(poolId);
        (uint256 interestReserve0, uint256 interestReserve1) = IPairPoolManager(pairPoolManager).marginLiquidity()
            .getInterestReserves(pairPoolManager, status.key.toId(), status);
        borrowedReserve0 = status.totalMirrorReserve0();
        borrowedReserve1 = status.totalMirrorReserve1();
        suppliedReserve0 = interestReserve0 + status.lendingReserve0();
        if (suppliedReserve0 > borrowedReserve0) {
            suppliedReserve0 -= borrowedReserve0;
        } else {
            suppliedReserve0 = 0;
        }
        suppliedReserve1 = interestReserve1 + status.lendingReserve1();
        if (suppliedReserve1 > borrowedReserve1) {
            suppliedReserve1 -= borrowedReserve1;
        } else {
            suppliedReserve1 = 0;
        }
    }

    function getProtocolSwapFeeAmount(uint256 totalFee) external view returns (uint256 feeAmount) {
        feeAmount = protocolSwapFee.part(totalFee);
    }

    function getProtocolMarginFeeAmount(uint256 totalFee) external view returns (uint256 feeAmount) {
        feeAmount = protocolMarginFee.part(totalFee);
    }

    function getProtocolInterestFeeAmount(uint256 totalFee) external view returns (uint256 feeAmount) {
        feeAmount = protocolInterestFee.part(totalFee);
    }

    // ******************** OWNER CALL ********************

    function setFeeTo(address _feeTo) external onlyOwner {
        feeTo = _feeTo;
    }

    function setMarginFee(uint24 _marginFee) external onlyOwner {
        marginFee = _marginFee;
    }

    function setProtocolSwapFee(uint24 _protocolSwapFee) external onlyOwner {
        protocolSwapFee = _protocolSwapFee;
    }

    function setProtocolMarginFee(uint24 _protocolMarginFee) external onlyOwner {
        protocolMarginFee = _protocolMarginFee;
    }

    function setProtocolInterestFee(uint24 _protocolInterestFee) external onlyOwner {
        protocolInterestFee = _protocolInterestFee;
    }

    function setRateStatus(RateStatus calldata _status) external onlyOwner {
        rateStatus = _status;
    }

    // ******************** FEE CALL ********************

    /// @inheritdoc IMarginFees
    function collectProtocolFees(address poolManager, address recipient, Currency currency, uint256 amount)
        external
        onlyFeeTo
        returns (uint256)
    {
        return IPairPoolManager(poolManager).collectProtocolFees(recipient, currency, amount);
    }
}
