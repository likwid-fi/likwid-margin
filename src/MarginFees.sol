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
import {HookStatus, BalanceStatus, FeeStatus} from "./types/HookStatus.sol";
import {IMarginHookManager} from "./interfaces/IMarginHookManager.sol";
import {IMarginFees} from "./interfaces/IMarginFees.sol";
import {TimeUtils} from "./libraries/TimeUtils.sol";

contract MarginFees is IMarginFees, Owned {
    using UQ112x112 for uint224;
    using PoolIdLibrary for PoolKey;
    using TimeUtils for uint32;

    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 public constant ONE_BILLION = 10 ** 9;
    uint256 public constant YEAR_SECONDS = 365 * 24 * 3600;

    uint24 initialLTV = 500000; // 50%
    uint24 liquidationLTV = 900000; // 90%
    uint24 public dynamicFeeDurationSeconds = 120;
    uint24 public dynamicFeeUnit = 10;
    address public feeTo;
    uint24 protocolFee = 3000; // 0.3%
    uint24 protocolMarginFee = 5000; // 0.5%

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
    }

    function getInitialLTV(address hook, PoolId poolId) external view returns (uint24 _initialLTV) {
        HookStatus memory status = IMarginHookManager(hook).getStatus(poolId);
        _initialLTV = status.feeStatus.initialLTV == 0 ? initialLTV : status.feeStatus.initialLTV;
    }

    function getLiquidationLTV(address hook, PoolId poolId) external view returns (uint24 _liquidationLTV) {
        HookStatus memory status = IMarginHookManager(hook).getStatus(poolId);
        _liquidationLTV = status.feeStatus.liquidationLTV == 0 ? liquidationLTV : status.feeStatus.liquidationLTV;
    }

    function getPoolFees(address hook, PoolId poolId)
        external
        view
        returns (uint24 _fee, uint24 _marginFee, uint24 _protocolFee, uint24 _protocolMarginFee)
    {
        IMarginHookManager hookManager = IMarginHookManager(hook);
        HookStatus memory status = hookManager.getStatus(poolId);
        (_fee, _protocolFee) = dynamicFee(status);
        _marginFee = status.feeStatus.marginFee;
        if (feeTo != address(0)) {
            _protocolMarginFee =
                status.feeStatus.protocolMarginFee > 0 ? status.feeStatus.protocolMarginFee : protocolMarginFee;
        }
    }

    function getProtocolMarginFee(address hook, PoolId poolId) external view returns (uint24 _protocolMarginFee) {
        IMarginHookManager hookManager = IMarginHookManager(hook);
        HookStatus memory status = hookManager.getStatus(poolId);
        if (feeTo != address(0)) {
            _protocolMarginFee =
                status.feeStatus.protocolMarginFee > 0 ? status.feeStatus.protocolMarginFee : protocolMarginFee;
        }
    }

    function dynamicFee(HookStatus memory status) public view returns (uint24 _fee, uint24 _protocolFee) {
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        uint256 timeElapsed;
        if (status.feeStatus.lastMarginTimestamp <= blockTS) {
            timeElapsed = blockTS - status.feeStatus.lastMarginTimestamp;
        } else {
            timeElapsed = (2 ** 32 - status.feeStatus.lastMarginTimestamp) + blockTS;
        }
        if (feeTo != address(0)) {
            _protocolFee = status.feeStatus.protocolFee == 0 ? protocolFee : status.feeStatus.protocolFee;
        }
        _fee = status.key.fee;
        if (timeElapsed < dynamicFeeDurationSeconds && status.feeStatus.lastPrice1X112 > 0) {
            (uint256 _reserve0, uint256 _reserve1) = _getReserves(status);
            uint224 price1X112 = UQ112x112.encode(uint112(_reserve0)).div(uint112(_reserve1));
            uint256 priceDiff = price1X112 > status.feeStatus.lastPrice1X112
                ? price1X112 - status.feeStatus.lastPrice1X112
                : status.feeStatus.lastPrice1X112 - price1X112;
            _fee = uint24(
                priceDiff * 1000 * dynamicFeeUnit * (dynamicFeeDurationSeconds - timeElapsed)
                    / (status.feeStatus.lastPrice1X112 * dynamicFeeDurationSeconds)
            ) * status.key.fee / 1000 + status.key.fee;
            if (_fee >= ONE_MILLION) {
                _fee = uint24(ONE_MILLION) - 1;
            }
        }
    }

    function _getReserves(HookStatus memory status) internal pure returns (uint256 _reserve0, uint256 _reserve1) {
        _reserve0 = status.realReserve0 + status.mirrorReserve0;
        _reserve1 = status.realReserve1 + status.mirrorReserve1;
    }

    function getBorrowRate(uint256 realReserve, uint256 mirrorReserve) public view returns (uint256) {
        if (realReserve == 0) {
            return rateStatus.rateBase;
        }
        uint256 useLevel = mirrorReserve * ONE_MILLION / (mirrorReserve + realReserve);
        if (useLevel >= rateStatus.useHighLevel) {
            return rateStatus.rateBase + rateStatus.useMiddleLevel * rateStatus.mLow
                + (rateStatus.useHighLevel - rateStatus.useMiddleLevel) * rateStatus.mMiddle
                + (useLevel - rateStatus.useHighLevel) * rateStatus.mHigh;
        } else if (useLevel >= rateStatus.useMiddleLevel) {
            return rateStatus.rateBase + rateStatus.useMiddleLevel * rateStatus.mLow
                + (useLevel - rateStatus.useMiddleLevel) * rateStatus.mMiddle;
        }
        return rateStatus.rateBase + useLevel * rateStatus.mLow;
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
        return getBorrowRate(realReserve, mirrorReserve);
    }

    function getBorrowRate(address hook, PoolId poolId, bool marginForOne) external view returns (uint256) {
        HookStatus memory status = IMarginHookManager(hook).getStatus(poolId);
        return getBorrowRate(status, marginForOne);
    }

    // ******************** OWNER CALL ********************
    function setLTV(uint24 _initialLTV, uint24 _liquidationLTV) external onlyOwner {
        initialLTV = _initialLTV;
        liquidationLTV = _liquidationLTV;
    }

    function setFeeTo(address _feeTo) external onlyOwner {
        feeTo = _feeTo;
    }

    function setRateStatus(RateStatus calldata _status) external onlyOwner {
        rateStatus = _status;
    }

    function setProtocolFee(uint24 _protocolFee) external onlyOwner {
        protocolFee = _protocolFee;
    }

    function setProtocolMarginFee(uint24 _protocolMarginFee) external onlyOwner {
        protocolMarginFee = _protocolMarginFee;
    }

    function setDynamicFeeDurationSeconds(uint24 _dynamicFeeDurationSeconds) external onlyOwner {
        dynamicFeeDurationSeconds = _dynamicFeeDurationSeconds;
    }

    function setDynamicFeeUnit(uint24 _dynamicFeeUnit) external onlyOwner {
        dynamicFeeUnit = _dynamicFeeUnit;
    }
}
