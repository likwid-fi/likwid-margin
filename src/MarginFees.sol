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
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";
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
    uint256 public constant LP_FLAG = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0;

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
        feeTo = initialOwner;
    }

    function getPoolId(PoolId poolId) external pure returns (uint256 uPoolId) {
        uPoolId = uint256(PoolId.unwrap(poolId)) & LP_FLAG;
    }

    function getLevelPool(uint256 uPoolId, uint8 level) external pure returns (uint256 lPoolId) {
        lPoolId = (uPoolId & LP_FLAG) + level;
    }

    function getPoolLiquidities(address marginLiquidity, PoolId poolId, address owner)
        external
        view
        returns (uint256[4] memory liquidities)
    {
        IMarginLiquidity liquidity = IMarginLiquidity(marginLiquidity);
        uint256 uPoolId = uint256(PoolId.unwrap(poolId)) & LP_FLAG;
        for (uint256 i = 0; i < 4; i++) {
            uint256 lPoolId = uPoolId + 1 + i;
            liquidities[i] = liquidity.balanceOf(owner, lPoolId);
        }
    }

    function getRetainSupplies(IMarginLiquidity liquidity, address hook, uint256 uPoolId)
        external
        view
        returns (uint256 retainSupply0, uint256 retainSupply1)
    {
        uint256 lPoolId = (uPoolId & LP_FLAG) + 1;
        retainSupply0 = retainSupply1 = liquidity.balanceOf(hook, lPoolId);
        lPoolId = (uPoolId & LP_FLAG) + 2;
        retainSupply0 += liquidity.balanceOf(hook, lPoolId);
        lPoolId = (uPoolId & LP_FLAG) + 3;
        retainSupply1 += liquidity.balanceOf(hook, lPoolId);
    }

    function getInitialLTV(address hook, PoolId poolId) external view returns (uint24 _initialLTV) {
        HookStatus memory status = IMarginHookManager(hook).getStatus(poolId);
        _initialLTV = status.feeStatus.initialLTV == 0 ? initialLTV : status.feeStatus.initialLTV;
    }

    function getLiquidationLTV(address hook, PoolId poolId) external view returns (uint24 _liquidationLTV) {
        HookStatus memory status = IMarginHookManager(hook).getStatus(poolId);
        _liquidationLTV = status.feeStatus.liquidationLTV == 0 ? liquidationLTV : status.feeStatus.liquidationLTV;
    }

    function getPoolFees(address hook, PoolId poolId) external view returns (uint24 _fee, uint24 _marginFee) {
        IMarginHookManager hookManager = IMarginHookManager(hook);
        HookStatus memory status = hookManager.getStatus(poolId);
        _fee = dynamicFee(status);
        _marginFee = status.feeStatus.marginFee;
    }

    function dynamicFee(HookStatus memory status) public view returns (uint24 _fee) {
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        uint256 timeElapsed;
        if (status.feeStatus.lastMarginTimestamp <= blockTS) {
            timeElapsed = blockTS - status.feeStatus.lastMarginTimestamp;
        } else {
            timeElapsed = (2 ** 32 - status.feeStatus.lastMarginTimestamp) + blockTS;
        }
        _fee = status.key.fee;
        if (timeElapsed < dynamicFeeDurationSeconds && status.feeStatus.lastPrice1X112 > 0) {
            (uint256 _reserve0, uint256 _reserve1) = _getReserves(status);
            uint224 price1X112 = UQ112x112.encode(uint112(_reserve0)).div(uint112(_reserve1));
            uint256 priceDiff = price1X112 > status.feeStatus.lastPrice1X112
                ? price1X112 - status.feeStatus.lastPrice1X112
                : status.feeStatus.lastPrice1X112 - price1X112;
            uint256 dFee = priceDiff * 1000 * dynamicFeeUnit * (dynamicFeeDurationSeconds - timeElapsed)
                / (status.feeStatus.lastPrice1X112 * dynamicFeeDurationSeconds) * status.key.fee / 1000 + status.key.fee;
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
