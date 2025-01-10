// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {RateStatus} from "./types/RateStatus.sol";
import {HookStatus, BalanceStatus} from "./types/HookStatus.sol";
import {IMarginHookManager} from "./interfaces/IMarginHookManager.sol";
import {IMarginFees} from "./interfaces/IMarginFees.sol";
import {TimeUtils} from "./libraries/TimeUtils.sol";

contract MarginFees is IMarginFees, Owned {
    using UQ112x112 for uint112;
    using UQ112x112 for uint224;
    using PoolIdLibrary for PoolKey;
    using TimeUtils for uint32;

    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 public constant ONE_BILLION = 10 ** 9;
    uint256 public constant YEAR_SECONDS = 365 * 24 * 3600;

    uint24 public constant minMarginLevel = 1200000; // 120%
    uint24 public constant liquidationMarginLevel = 1100000; // 90%
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

    function getMarginLevels() external pure returns (uint24 _minMarginLevel, uint24 _liquidationMarginLevel) {
        _minMarginLevel = minMarginLevel;
        _liquidationMarginLevel = liquidationMarginLevel;
    }

    function getPoolFees(address hook, PoolId poolId) external view returns (uint24 _fee, uint24 _marginFee) {
        IMarginHookManager hookManager = IMarginHookManager(hook);
        HookStatus memory status = hookManager.getStatus(poolId);
        _fee = dynamicFee(status);
        _marginFee = status.marginFee;
    }

    function dynamicFee(HookStatus memory status) public view returns (uint24 _fee) {
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        uint256 timeElapsed;
        if (status.marginTimestampLast <= blockTS) {
            timeElapsed = blockTS - status.marginTimestampLast;
        } else {
            timeElapsed = (2 ** 32 - status.marginTimestampLast) + blockTS;
        }
        _fee = status.key.fee;
        uint256 lastPrice1X112 = status.lastPrice1X112;
        if (timeElapsed < dynamicFeeDurationSeconds && lastPrice1X112 > 0) {
            (uint256 _reserve0, uint256 _reserve1) = _getReserves(status);
            uint224 price1X112 = UQ112x112.encode(uint112(_reserve0)).div(uint112(_reserve1));
            uint256 priceDiff = price1X112 > lastPrice1X112 ? price1X112 - lastPrice1X112 : lastPrice1X112 - price1X112;
            uint256 dFee = priceDiff * 1000 * dynamicFeeUnit * (dynamicFeeDurationSeconds - timeElapsed)
                / (lastPrice1X112 * dynamicFeeDurationSeconds) * _fee / 1000 + _fee;
            if (dFee >= ONE_MILLION) {
                _fee = uint24(ONE_MILLION) - 1;
            } else {
                _fee = uint24(dFee);
            }
        }
    }

    function _getReserves(HookStatus memory status) internal pure returns (uint256 _reserve0, uint256 _reserve1) {
        _reserve0 = status.realReserve0 + status.mirrorReserve0;
        _reserve1 = status.realReserve1 + status.mirrorReserve1;
    }

    function getBorrowRateByReserves(uint256 realReserve, uint256 mirrorReserve) public view returns (uint256 rate) {
        rate = rateStatus.rateBase;
        if (mirrorReserve == 0) {
            return rate;
        }
        uint256 useLevel = mirrorReserve * ONE_MILLION / (mirrorReserve + realReserve);
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

    function getBorrowRateCumulativeLast(HookStatus memory status, bool marginForOne) public view returns (uint256) {
        (, uint256 timeElapsed) = status.blockTimestampLast.getTimeElapsedMillisecond();
        uint256 saveLast = marginForOne ? status.rate0CumulativeLast : status.rate1CumulativeLast;
        uint256 rateLast = ONE_BILLION + getBorrowRate(status, marginForOne) * timeElapsed / YEAR_SECONDS;
        return saveLast * rateLast / ONE_BILLION;
    }

    function getBorrowRateCumulativeLast(address hook, PoolId poolId, bool marginForOne)
        external
        view
        returns (uint256)
    {
        HookStatus memory status = IMarginHookManager(hook).getStatus(poolId);
        (, uint256 timeElapsed) = status.blockTimestampLast.getTimeElapsedMillisecond();
        uint256 saveLast = marginForOne ? status.rate0CumulativeLast : status.rate1CumulativeLast;
        uint256 rateLast = ONE_BILLION + getBorrowRate(status, marginForOne) * timeElapsed / YEAR_SECONDS;
        return saveLast * rateLast / ONE_BILLION;
    }

    function getBorrowRate(HookStatus memory status, bool marginForOne) public view returns (uint256) {
        uint256 realReserve = marginForOne ? status.realReserve0 : status.realReserve1;
        uint256 mirrorReserve = marginForOne ? status.mirrorReserve0 : status.mirrorReserve1;
        return getBorrowRateByReserves(realReserve, mirrorReserve);
    }

    function getBorrowRate(address hook, PoolId poolId, bool marginForOne) external view returns (uint256) {
        HookStatus memory status = IMarginHookManager(hook).getStatus(poolId);
        return getBorrowRate(status, marginForOne);
    }

    function _getInterests(HookStatus memory status) internal pure returns (uint112 interest0, uint112 interest1) {
        interest0 = status.interestRatio0X112.mul(status.realReserve0 + status.mirrorReserve0).decode();
        interest1 = status.interestRatio1X112.mul(status.realReserve1 + status.mirrorReserve1).decode();
    }

    function getInterests(HookStatus calldata status) external pure returns (uint112 interest0, uint112 interest1) {
        (interest0, interest1) = _getInterests(status);
    }

    function getInterests(address hook, PoolId poolId) external view returns (uint112 interest0, uint112 interest1) {
        IMarginHookManager hookManager = IMarginHookManager(hook);
        HookStatus memory status = hookManager.getStatus(poolId);
        (interest0, interest1) = _getInterests(status);
    }

    // ******************** OWNER CALL ********************

    function setFeeTo(address _feeTo) external onlyOwner {
        feeTo = _feeTo;
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
}
