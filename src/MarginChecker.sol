// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {Math} from "./libraries/Math.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {MarginPosition, MarginPositionVo, BurnParams} from "./types/MarginPosition.sol";
import {IMarginHookManager} from "./interfaces/IMarginHookManager.sol";
import {IMarginChecker} from "./interfaces/IMarginChecker.sol";
import {IMarginOracleReader} from "./interfaces/IMarginOracleReader.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";

contract MarginChecker is IMarginChecker, Owned {
    using UQ112x112 for uint224;
    using UQ112x112 for uint112;
    using PriceMath for uint224;

    uint256 public constant ONE_MILLION = 10 ** 6;
    uint24 liquidateMillion = 10 ** 4;
    uint24[] leverageParts = [380, 200, 100, 40, 9];

    constructor(address initialOwner) Owned(initialOwner) {}

    function setLiquidateMillion(uint24 _liquidateMillion) external onlyOwner {
        liquidateMillion = _liquidateMillion;
    }

    function getLiquidateMillion() external view returns (uint24) {
        return liquidateMillion;
    }

    function setLeverageParts(uint24[] calldata _leverageParts) external onlyOwner {
        leverageParts = _leverageParts;
    }

    function getLeverageParts() external view returns (uint24[] memory) {
        return leverageParts;
    }

    function checkLiquidate(address, uint256, bytes calldata) external pure returns (bool) {
        return true;
    }

    function getMaxDecrease(MarginPosition memory _position, address hook) external view returns (uint256 maxAmount) {
        (uint256 reserve0, uint256 reserve1) = IMarginHookManager(hook).getReserves(_position.poolId);
        (uint256 reserveBorrow, uint256 reserveMargin) =
            _position.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 debtAmount = reserveMargin * _position.borrowAmount / reserveBorrow;
        if (debtAmount > _position.marginTotal) {
            uint256 newMarginAmount = (debtAmount - _position.marginTotal) * 1000 / 800;
            if (newMarginAmount < _position.marginAmount) {
                maxAmount = _position.marginAmount - newMarginAmount;
            }
        } else {
            maxAmount = uint256(_position.marginAmount) * 800 / 1000;
        }
    }

    function getReserves(PoolId poolId, bool marginForOne, address hook)
        public
        view
        returns (uint256 reserveBorrow, uint256 reserveMargin)
    {
        address marginOracle = IMarginHookManager(hook).marginOracle();
        if (marginOracle == address(0)) {
            (uint256 reserve0, uint256 reserve1) = IMarginHookManager(hook).getReserves(poolId);
            (reserveBorrow, reserveMargin) = marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        } else {
            (uint224 reserves,) = IMarginOracleReader(marginOracle).observeNow(poolId, hook);
            (reserveBorrow, reserveMargin) = marginForOne
                ? (reserves.getReverse0(), reserves.getReverse1())
                : (reserves.getReverse1(), reserves.getReverse0());
        }
    }

    function checkLiquidate(address manager, uint256 positionId)
        public
        view
        returns (bool liquidated, uint256 borrowAmount)
    {
        IMarginPositionManager positionManager = IMarginPositionManager(manager);
        MarginPosition memory _position = positionManager.getPosition(positionId);
        return checkLiquidate(_position, positionManager.getHook());
    }

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
            uint24 marginLevel = hookManager.marginFees().liquidationMarginLevel();
            liquidated = _position.marginAmount + _position.marginTotal < debtAmount * marginLevel / ONE_MILLION;
        }
    }

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

    function checkLiquidate(PoolId poolId, bool marginForOne, address hook, MarginPosition[] memory inPositions)
        external
        view
        returns (bool[] memory liquidatedList, uint256[] memory borrowAmountList)
    {
        IMarginHookManager hookManager = IMarginHookManager(hook);
        (uint256 reserveBorrow, uint256 reserveMargin) = getReserves(poolId, marginForOne, hook);
        uint24 marginLevel = hookManager.marginFees().liquidationMarginLevel();
        uint256 rateLast = hookManager.marginFees().getBorrowRateCumulativeLast(hook, poolId, marginForOne);
        bytes32 bytes32PoolId = PoolId.unwrap(poolId);
        liquidatedList = new bool[](inPositions.length);
        borrowAmountList = new uint256[](inPositions.length);
        for (uint256 i = 0; i < inPositions.length; i++) {
            MarginPosition memory _position = inPositions[i];
            if (PoolId.unwrap(_position.poolId) == bytes32PoolId && _position.marginForOne == marginForOne) {
                if (_position.borrowAmount > 0) {
                    uint256 borrowAmount = uint256(_position.borrowAmount);
                    uint256 allMarginAmount = _position.marginAmount + _position.marginTotal;
                    if (_position.rateCumulativeLast > 0) {
                        borrowAmount = borrowAmount * rateLast / _position.rateCumulativeLast;
                    }
                    uint256 debtAmount = reserveMargin * borrowAmount / reserveBorrow;
                    liquidatedList[i] = allMarginAmount < debtAmount * marginLevel / ONE_MILLION;
                    borrowAmountList[i] = borrowAmount;
                }
            }
        }
    }
}
