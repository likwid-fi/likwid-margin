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
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {RateStatus} from "./types/RateStatus.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IMarginFees} from "./interfaces/IMarginFees.sol";
import {TimeUtils} from "./libraries/TimeUtils.sol";

contract MarginFees is IMarginFees, Owned {
    using UQ112x112 for uint112;
    using UQ112x112 for uint224;
    using PoolIdLibrary for PoolKey;
    using TimeUtils for uint32;
    using FeeLibrary for uint24;
    using PerLibrary for uint256;

    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 public constant ONE_BILLION = 10 ** 9;
    uint256 public constant YEAR_SECONDS = 365 * 24 * 3600;

    uint24 public constant liquidationMarginLevel = 1100000; // 110%
    uint24 public marginFee = 3000; // 0.3%
    uint24 public protocolFee = 50000; // 5%
    uint24 public dynamicFeeDurationSeconds = 120;
    uint24 public dynamicFeeUnit = 10;
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
    function getPoolFees(address pool, PoolId poolId) external view returns (uint24 _fee, uint24 _marginFee) {
        IPairPoolManager poolManager = IPairPoolManager(pool);
        PoolStatus memory status = poolManager.getStatus(poolId);
        _fee = dynamicFee(status);
        _marginFee = status.marginFee == 0 ? marginFee : status.marginFee;
    }

    /// @inheritdoc IMarginFees
    function dynamicFee(PoolStatus memory status) public view returns (uint24 _fee) {
        uint256 timeElapsed = status.marginTimestampLast.getTimeElapsed();
        _fee = status.key.fee;
        uint256 lastPrice1X112 = status.lastPrice1X112;
        if (timeElapsed < dynamicFeeDurationSeconds && lastPrice1X112 > 0) {
            uint256 timeDiff = uint256(dynamicFeeDurationSeconds - timeElapsed);
            (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
            uint224 price1X112 = UQ112x112.encode(uint112(_reserve0)).div(uint112(_reserve1));
            uint256 priceDiff = price1X112 > lastPrice1X112 ? price1X112 - lastPrice1X112 : lastPrice1X112 - price1X112;
            uint256 timeMul = timeDiff.mulMillionDiv(uint256(dynamicFeeDurationSeconds));
            uint256 feeUp = Math.mulDiv(priceDiff * dynamicFeeUnit * _fee, timeMul, lastPrice1X112).divMillion();
            uint256 dFee = feeUp + _fee;
            if (dFee >= ONE_MILLION) {
                _fee = uint24(ONE_MILLION) - 1;
            } else {
                _fee = uint24(dFee);
                if (timeElapsed == 0) {
                    uint24 oneBlockFee = 20 * status.key.fee;
                    if (oneBlockFee > _fee) {
                        _fee = oneBlockFee;
                    }
                }
            }
        }
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
        uint256 useLevel = Math.mulDiv(mirrorReserve, ONE_MILLION, (mirrorReserve + realReserve));
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
        uint256 timeElapsed = status.blockTimestampLast.getTimeElapsedMillisecond();
        uint256 rate0 = getBorrowRateByReserves(status.realReserve0, status.mirrorReserve0);
        uint256 rate0Last = ONE_BILLION + rate0 * timeElapsed / YEAR_SECONDS;
        rate0CumulativeLast = status.rate0CumulativeLast * rate0Last / ONE_BILLION;
        uint256 rate1 = getBorrowRateByReserves(status.realReserve1, status.mirrorReserve1);
        uint256 rate1Last = ONE_BILLION + rate1 * timeElapsed / YEAR_SECONDS;
        rate1CumulativeLast = status.rate1CumulativeLast * rate1Last / ONE_BILLION;
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
        uint256 realReserve = marginForOne ? status.realReserve0 : status.realReserve1;
        uint256 mirrorReserve = marginForOne ? status.mirrorReserve0 : status.mirrorReserve1;
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

    function setDynamicFeeDurationSeconds(uint24 _dynamicFeeDurationSeconds) external onlyOwner {
        dynamicFeeDurationSeconds = _dynamicFeeDurationSeconds;
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
