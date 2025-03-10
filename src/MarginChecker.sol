// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HookStatus} from "./types/HookStatus.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {MarginPosition, MarginPositionVo, BurnParams} from "./types/MarginPosition.sol";
import {IMarginHookManager} from "./interfaces/IMarginHookManager.sol";
import {IMarginChecker} from "./interfaces/IMarginChecker.sol";
import {IMarginOracleReader} from "./interfaces/IMarginOracleReader.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";

contract MarginChecker is IMarginChecker, Owned {
    using UQ112x112 for uint224;
    using UQ112x112 for uint112;
    using PriceMath for uint224;
    using PerLibrary for uint256;
    using FeeLibrary for uint24;

    uint256 public constant ONE_MILLION = 10 ** 6;
    uint24 callerProfit = 10 ** 4;
    uint24 protocolProfit = 0;
    uint24[] leverageThousandths = [380, 200, 100, 40, 9];

    constructor(address initialOwner) Owned(initialOwner) {}

    function setCallerProfit(uint24 _callerProfit) external onlyOwner {
        callerProfit = _callerProfit;
    }

    function setProtocolProfit(uint24 _protocolProfit) external onlyOwner {
        protocolProfit = _protocolProfit;
    }

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

    /// @inheritdoc IMarginChecker
    function getMarginTotal(address hook, PoolId poolId, bool marginForOne, uint24 leverage, uint256 marginAmount)
        external
        view
        returns (uint256 marginWithoutFee, uint256 borrowAmount)
    {
        IMarginHookManager hookManager = IMarginHookManager(hook);
        (, uint24 marginFee) = hookManager.marginFees().getPoolFees(address(hook), poolId);
        uint256 marginTotal = marginAmount * leverage;
        borrowAmount = hookManager.getAmountIn(poolId, marginForOne, marginTotal);
        marginWithoutFee = marginFee.deductFrom(marginTotal);
    }

    function _getMarginReserve(IMarginHookManager hookManager, PoolId poolId, bool marginForOne)
        internal
        view
        returns (uint256 marginReserve)
    {
        HookStatus memory status = hookManager.getStatus(poolId);
        (uint256 _totalSupply, uint256 retainSupply0, uint256 retainSupply1) =
            hookManager.marginLiquidity().getPoolSupplies(address(hookManager), poolId);
        uint256 marginReserve0 = Math.mulDiv(_totalSupply - retainSupply0, status.realReserve0, _totalSupply);
        uint256 marginReserve1 = Math.mulDiv(_totalSupply - retainSupply1, status.realReserve1, _totalSupply);
        marginReserve = (marginForOne ? marginReserve1 : marginReserve0);
    }

    /// @inheritdoc IMarginChecker
    function getMarginMax(address hook, PoolId poolId, bool marginForOne, uint24 leverage)
        external
        view
        returns (uint256 marginMax, uint256 borrowAmount)
    {
        IMarginHookManager hookManager = IMarginHookManager(hook);
        uint256 marginMaxTotal = _getMarginReserve(hookManager, poolId, marginForOne);
        if (marginMaxTotal > 1000) {
            (uint256 reserve0, uint256 reserve1) = hookManager.getReserves(poolId);
            uint256 marginMaxReserve = (marginForOne ? reserve1 : reserve0);
            uint24 part = leverageThousandths[leverage - 1];
            marginMaxReserve = marginMaxReserve * part / 1000;
            marginMaxTotal = Math.min(marginMaxTotal, marginMaxReserve);
            marginMaxTotal -= 1000;
        }
        borrowAmount = hookManager.getAmountIn(poolId, marginForOne, marginMaxTotal);
        marginMax = marginMaxTotal / leverage;
    }

    /// @inheritdoc IMarginChecker
    function getMaxDecrease(MarginPosition memory _position, address hook) external view returns (uint256 maxAmount) {
        IMarginHookManager hookManager = IMarginHookManager(hook);
        (uint256 reserveBorrow, uint256 reserveMargin) = getReserves(_position.poolId, _position.marginForOne, hook);
        uint256 debtAmount = reserveMargin * _position.borrowAmount / reserveBorrow;
        uint256 liquidationMarginLevel = hookManager.marginFees().liquidationMarginLevel();
        uint256 liquidatedAmount = debtAmount.mulDivMillion(liquidationMarginLevel);
        uint256 assetAmount = uint256(_position.marginAmount) + _position.marginTotal;
        if (liquidatedAmount < assetAmount) {
            maxAmount = Math.mulDiv(assetAmount - liquidatedAmount, 800, 1000);
        }
        maxAmount = Math.min(uint256(_position.marginAmount), maxAmount);
    }

    /// @inheritdoc IMarginChecker
    function getOracleReserves(PoolId poolId, address hook) public view returns (uint224 reserves) {
        address marginOracle = IMarginHookManager(hook).marginOracle();
        if (marginOracle == address(0)) {
            reserves = 0;
        } else {
            (reserves,) = IMarginOracleReader(marginOracle).observeNow(poolId, hook);
        }
    }

    /// @inheritdoc IMarginChecker
    function getReserves(PoolId poolId, bool marginForOne, address hook)
        public
        view
        returns (uint256 reserveBorrow, uint256 reserveMargin)
    {
        uint224 oracleReserves = getOracleReserves(poolId, hook);
        if (oracleReserves == 0) {
            (uint256 reserve0, uint256 reserve1) = IMarginHookManager(hook).getReserves(poolId);
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
        return checkLiquidate(_position, positionManager.getHook());
    }

    /// @inheritdoc IMarginChecker
    function checkLiquidate(MarginPosition memory _position, address hook)
        public
        view
        returns (bool liquidated, uint256 borrowAmount)
    {
        if (_position.borrowAmount > 0) {
            IMarginHookManager hookManager = IMarginHookManager(hook);
            borrowAmount = uint256(_position.borrowAmount);
            if (_position.rateCumulativeLast > 0) {
                uint256 rateLast =
                    hookManager.marginFees().getBorrowRateCumulativeLast(hook, _position.poolId, _position.marginForOne);
                borrowAmount = borrowAmount * rateLast / _position.rateCumulativeLast;
            }
            (uint256 reserveBorrow, uint256 reserveMargin) = getReserves(_position.poolId, _position.marginForOne, hook);
            uint256 debtAmount = reserveMargin * borrowAmount / reserveBorrow;
            uint256 liquidationMarginLevel = hookManager.marginFees().liquidationMarginLevel();
            uint256 liquidatedAmount = debtAmount.mulDivMillion(liquidationMarginLevel);
            uint256 assetAmount = uint256(_position.marginAmount) + _position.marginTotal;
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
    function checkLiquidate(PoolId poolId, bool marginForOne, address hook, MarginPosition[] memory inPositions)
        external
        view
        returns (bool[] memory liquidatedList, uint256[] memory borrowAmountList)
    {
        IMarginHookManager hookManager = IMarginHookManager(hook);
        (uint256 reserveBorrow, uint256 reserveMargin) = getReserves(poolId, marginForOne, hook);
        uint24 liquidationMarginLevel = hookManager.marginFees().liquidationMarginLevel();
        uint256 rateLast = hookManager.marginFees().getBorrowRateCumulativeLast(hook, poolId, marginForOne);
        bytes32 bytes32PoolId = PoolId.unwrap(poolId);
        liquidatedList = new bool[](inPositions.length);
        borrowAmountList = new uint256[](inPositions.length);
        for (uint256 i = 0; i < inPositions.length; i++) {
            MarginPosition memory _position = inPositions[i];
            if (PoolId.unwrap(_position.poolId) == bytes32PoolId && _position.marginForOne == marginForOne) {
                if (_position.borrowAmount > 0) {
                    uint256 borrowAmount = uint256(_position.borrowAmount);
                    uint256 assetAmount = _position.marginAmount + _position.marginTotal;
                    if (_position.rateCumulativeLast > 0) {
                        borrowAmount = borrowAmount * rateLast / _position.rateCumulativeLast;
                    }
                    uint256 debtAmount = reserveMargin * borrowAmount / reserveBorrow;
                    uint256 liquidatedAmount = debtAmount.mulDivMillion(liquidationMarginLevel);
                    liquidatedList[i] = assetAmount < liquidatedAmount;
                    borrowAmountList[i] = borrowAmount;
                }
            }
        }
    }
}
