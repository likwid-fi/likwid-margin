// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
// Local
import {BasePositionManager} from "./base/BasePositionManager.sol";
import {ReentrancyGuardTransient} from "./external/openzeppelin-contracts/ReentrancyGuardTransient.sol";
import {CurrencyUtils} from "./libraries/CurrencyUtils.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {ILendingPoolManager} from "./interfaces/ILendingPoolManager.sol";
import {IMarginChecker} from "./interfaces/IMarginChecker.sol";
import {MarginPosition, MarginPositionVo} from "./types/MarginPosition.sol";
import {BurnParams} from "./types/BurnParams.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {LiquidateStatus} from "./types/LiquidateStatus.sol";
import {ReleaseParams} from "./types/ReleaseParams.sol";
import {MarginParams} from "./types/MarginParams.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {TimeUtils} from "./libraries/TimeUtils.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";

contract MarginPositionManager is IMarginPositionManager, BasePositionManager {
    using CurrencyLibrary for Currency;
    using CurrencyUtils for Currency;
    using UQ112x112 for *;
    using PriceMath for uint224;
    using TimeUtils for uint32;
    using PerLibrary for uint256;
    using FeeLibrary for uint24;

    error PairNotExists();
    error PositionLiquidated();
    error MarginTransferFailed(uint256 amount);
    error InsufficientAmount(uint256 amount);
    error InsufficientBorrowReceived();

    event Mint(PoolId indexed poolId, address indexed sender, address indexed to, uint256 positionId);
    event Burn(PoolId indexed poolId, address indexed sender, uint256 positionId, uint8 burnType);
    event Margin(
        PoolId indexed poolId,
        address indexed owner,
        uint256 positionId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 borrowAmount,
        bool marginForOne
    );
    event RepayClose(
        PoolId indexed poolId,
        address indexed sender,
        uint256 positionId,
        uint256 releaseMarginAmount,
        uint256 releaseMarginTotal,
        uint256 repayAmount,
        uint256 repayRawAmount,
        int256 pnlAmount
    );
    event Modify(
        PoolId indexed poolId,
        address indexed sender,
        uint256 positionId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 borrowAmount,
        int256 changeAmount
    );
    event Liquidate(
        PoolId indexed poolId,
        address indexed sender,
        uint256 positionId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 borrowAmount,
        uint256 oracleReserves,
        uint256 statusReserves
    );

    enum BurnType {
        CLOSE,
        LIQUIDATE
    }

    mapping(uint256 => MarginPosition) private _positions;
    mapping(PoolId => mapping(bool => mapping(address => uint256))) private _marginPositionIds;
    mapping(PoolId => mapping(bool => mapping(address => uint256))) private _borrowPositionIds;

    constructor(address initialOwner, IPairPoolManager _pairPoolManager, IMarginChecker _checker)
        BasePositionManager("LIKWIDMarginPositionManager", "LMPM", initialOwner, _pairPoolManager, _checker)
    {
        pairPoolManager = _pairPoolManager;
        lendingPoolManager = _pairPoolManager.lendingPoolManager();
        checker = _checker;
    }

    function _burnPosition(uint256 positionId, BurnType burnType) internal {
        // _burn(positionId);
        MarginPosition memory _position = _positions[positionId];
        require(_position.rateCumulativeLast > 0, "ALREADY_BURNT");
        if (_position.marginTotal == 0) {
            delete _borrowPositionIds[_position.poolId][_position.marginForOne][ownerOf(positionId)];
        } else {
            delete _marginPositionIds[_position.poolId][_position.marginForOne][ownerOf(positionId)];
        }
        delete _positions[positionId];
        emit Burn(_position.poolId, msg.sender, positionId, uint8(burnType));
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        MarginPosition memory _position = _positions[tokenId];
        if (_position.marginTotal == 0) {
            delete _borrowPositionIds[_position.poolId][_position.marginForOne][from];
            _borrowPositionIds[_position.poolId][_position.marginForOne][to] = tokenId;
        } else {
            delete _marginPositionIds[_position.poolId][_position.marginForOne][from];
            _marginPositionIds[_position.poolId][_position.marginForOne][to] = tokenId;
        }

        return from;
    }

    /// @inheritdoc IMarginPositionManager
    function getPairPool() external view returns (address _pairPoolManager) {
        _pairPoolManager = address(pairPoolManager);
    }

    /// @inheritdoc IMarginPositionManager
    function getPosition(uint256 positionId) external view returns (MarginPosition memory _position) {
        _position = _getPosition(positionId);
    }

    /// @inheritdoc IMarginPositionManager
    function estimatePNL(uint256 positionId, uint256 closeMillionth) public view returns (int256 pnlAmount) {
        MarginPosition memory _position = _getPosition(positionId);
        PoolStatus memory _status = pairPoolManager.getStatus(_position.poolId);
        pnlAmount = checker.estimatePNL(pairPoolManager, _status, _position, closeMillionth);
    }

    function getPositions(uint256[] calldata positionIds) external view returns (MarginPositionVo[] memory _position) {
        _position = new MarginPositionVo[](positionIds.length);
        for (uint256 i = 0; i < positionIds.length; i++) {
            _position[i].position = _getPosition(positionIds[i]);
            _position[i].pnl = estimatePNL(positionIds[i], PerLibrary.ONE_MILLION);
        }
    }

    function getMarginPositionId(PoolId poolId, bool marginForOne, address owner)
        external
        view
        returns (uint256 _positionId)
    {
        _positionId = _marginPositionIds[poolId][marginForOne][owner];
    }

    function getBorrowPositionId(PoolId poolId, bool marginForOne, address owner)
        external
        view
        returns (uint256 _positionId)
    {
        _positionId = _marginPositionIds[poolId][marginForOne][owner];
    }

    /// @inheritdoc IMarginPositionManager
    function margin(MarginParams memory params) external payable ensure(params.deadline) returns (uint256, uint256) {
        PoolStatus memory _status = pairPoolManager.getStatus(params.poolId);
        Currency marginCurrency = params.marginForOne ? _status.key.currency1 : _status.key.currency0;
        uint256 sendValue = marginCurrency.checkAmount(params.marginAmount);
        uint256 positionId;
        bool isMargin = params.leverage > 0;
        if (isMargin) {
            positionId = _marginPositionIds[params.poolId][params.marginForOne][params.recipient];
        } else {
            positionId = _borrowPositionIds[params.poolId][params.marginForOne][params.recipient];
        }
        // call margin
        params.minMarginLevel = checker.minMarginLevel();
        params = pairPoolManager.margin{value: sendValue}(msg.sender, params);
        if (params.borrowMaxAmount > 0 && params.borrowAmount > params.borrowMaxAmount) {
            revert InsufficientBorrowReceived();
        }
        if (!_checkMinMarginLevel(params, _status)) revert InsufficientAmount(params.marginAmount);
        if (positionId == 0) {
            _mint(params.recipient, (positionId = nextId++));
            emit Mint(params.poolId, msg.sender, params.recipient, positionId);
            uint256 rateCumulativeLast = params.marginForOne ? _status.rate0CumulativeLast : _status.rate1CumulativeLast;
            MarginPosition memory _position = MarginPosition({
                poolId: params.poolId,
                marginForOne: params.marginForOne,
                marginAmount: params.marginAmount.toUint112(),
                marginTotal: params.marginTotal.toUint112(),
                borrowAmount: params.borrowAmount.toUint112(),
                rawBorrowAmount: params.borrowAmount.toUint112(),
                rateCumulativeLast: rateCumulativeLast
            });
            (bool liquidated,) = checker.checkLiquidate(pairPoolManager, _status, _position);
            if (liquidated) revert PositionLiquidated();
            if (isMargin) {
                _marginPositionIds[params.poolId][params.marginForOne][params.recipient] = positionId;
            } else {
                _borrowPositionIds[params.poolId][params.marginForOne][params.recipient] = positionId;
            }
            _positions[positionId] = _position;
        } else {
            require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
            MarginPosition storage _position = _positions[positionId];
            _updatePosition(_position, _status);
            _position.marginAmount += params.marginAmount.toUint112();
            _position.marginTotal += params.marginTotal.toUint112();
            _position.rawBorrowAmount += params.borrowAmount.toUint112();
            _position.borrowAmount = _position.borrowAmount + params.borrowAmount.toUint112();
            (bool liquidated,) = checker.checkLiquidate(pairPoolManager, _status, _position);
            if (liquidated) revert PositionLiquidated();
        }
        emit Margin(
            params.poolId,
            params.recipient,
            positionId,
            params.marginAmount,
            params.marginTotal,
            params.borrowAmount,
            params.marginForOne
        );
        if (msg.value > sendValue) transferNative(msg.sender, msg.value - sendValue);
        return (positionId, params.borrowAmount);
    }

    function _repay(
        uint256 positionId,
        PoolStatus memory _status,
        MarginPosition storage _position,
        ReleaseParams memory params
    ) internal returns (uint256 releaseAmount) {
        int256 pnlAmount = checker.estimatePNL(
            pairPoolManager, _status, _position, params.repayAmount.mulMillionDiv(_position.borrowAmount)
        );
        uint128 borrowAmount = _position.borrowAmount;
        uint256 releaseMargin = Math.mulDiv(_position.marginAmount, params.repayAmount, borrowAmount);
        uint256 releaseTotal = Math.mulDiv(_position.marginTotal, params.repayAmount, borrowAmount);
        emit RepayClose(
            _position.poolId,
            msg.sender,
            positionId,
            releaseMargin,
            releaseTotal,
            params.repayAmount,
            params.rawBorrowAmount,
            pnlAmount
        );
        _position.borrowAmount = borrowAmount - params.repayAmount.toUint112();
        if (_position.borrowAmount == 0) {
            _burnPosition(positionId, BurnType.CLOSE);
        } else {
            _position.marginAmount -= uint128(releaseMargin);
            _position.marginTotal -= uint128(releaseTotal);
            _position.rawBorrowAmount -= uint128(params.rawBorrowAmount);
        }
        releaseAmount = releaseMargin + releaseTotal;
    }

    /// @inheritdoc IMarginPositionManager
    function repay(uint256 positionId, uint256 repayAmount, uint256 deadline)
        external
        payable
        nonReentrant
        ensure(deadline)
    {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        MarginPosition storage _position = _positions[positionId];
        PoolStatus memory _status = pairPoolManager.getStatus(_position.poolId);
        _updatePosition(_position, _status);
        (bool liquidated,) = checker.checkLiquidate(pairPoolManager, _status, _position);
        if (liquidated) revert PositionLiquidated();
        (Currency borrowCurrency, Currency marginCurrency) = _position.marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        if (repayAmount > _position.borrowAmount) {
            repayAmount = _position.borrowAmount;
        }
        ReleaseParams memory params = ReleaseParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: msg.sender,
            rawBorrowAmount: 0,
            repayAmount: repayAmount,
            releaseAmount: 0,
            deadline: deadline
        });
        params.rawBorrowAmount = uint256(_position.rawBorrowAmount) * repayAmount / _position.borrowAmount;
        uint256 sendValue = borrowCurrency.checkAmount(repayAmount);
        pairPoolManager.release{value: sendValue}(params);
        if (msg.value > sendValue) {
            transferNative(msg.sender, msg.value - sendValue);
        }
        PoolId poolId = _position.poolId;
        // update position
        uint256 releaseAmount = _repay(positionId, _status, _position, params);
        // withdraw original
        lendingPoolManager.withdrawOriginal(msg.sender, poolId, marginCurrency, releaseAmount);
    }

    function _close(
        uint256 positionId,
        uint256 closeMillionth,
        int256 pnlMinAmount,
        MarginPosition storage _position,
        Currency marginCurrency,
        ReleaseParams memory params
    ) internal returns (uint256 profit) {
        uint256 releaseMargin = uint256(_position.marginAmount).mulDivMillion(closeMillionth);
        uint256 releaseTotal = uint256(_position.marginTotal).mulDivMillion(closeMillionth);
        int256 pnlAmount;
        {
            uint256 releaseMarginReal =
                lendingPoolManager.computeRealAmount(_position.poolId, marginCurrency, releaseMargin);
            uint256 releaseTotalReal =
                lendingPoolManager.computeRealAmount(_position.poolId, marginCurrency, releaseTotal);
            pnlAmount = int256(releaseTotalReal) - int256(params.releaseAmount);
            require(pnlMinAmount == 0 || pnlMinAmount <= pnlAmount, "InsufficientOutputReceived");
            if (pnlAmount >= 0) {
                profit = uint256(pnlAmount) + releaseMarginReal;
            } else {
                if (uint256(-pnlAmount) < releaseMarginReal) {
                    profit = releaseMarginReal - uint256(-pnlAmount);
                } else if (uint256(-pnlAmount) < uint256(_position.marginAmount)) {
                    releaseMarginReal = uint256(-pnlAmount);
                } else {
                    // liquidated
                    revert PositionLiquidated();
                }
            }
        }
        PoolId poolId = _position.poolId;
        // update _position
        _position.borrowAmount = _position.borrowAmount - params.repayAmount.toUint112();

        if (_position.borrowAmount == 0) {
            _burnPosition(positionId, BurnType.CLOSE);
        } else {
            _position.marginAmount -= releaseMargin.toUint112();
            _position.marginTotal -= releaseTotal.toUint112();
            _position.rawBorrowAmount -= params.rawBorrowAmount.toUint112();
        }

        emit RepayClose(
            poolId,
            msg.sender,
            positionId,
            releaseMargin,
            releaseTotal,
            params.repayAmount,
            params.rawBorrowAmount,
            pnlAmount
        );

        if (profit > 0) {
            lendingPoolManager.withdraw(msg.sender, poolId, marginCurrency, profit);
        }
    }

    /// @inheritdoc IMarginPositionManager
    function close(uint256 positionId, uint256 closeMillionth, int256 pnlMinAmount, uint256 deadline)
        external
        nonReentrant
        ensure(deadline)
    {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        require(closeMillionth <= PerLibrary.ONE_MILLION, "MILLIONTH_ERROR");
        MarginPosition storage _position = _positions[positionId];
        PoolStatus memory _status = pairPoolManager.getStatus(_position.poolId);
        _updatePosition(_position, _status);
        Currency marginCurrency = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        ReleaseParams memory params = ReleaseParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: address(this),
            rawBorrowAmount: 0,
            repayAmount: 0,
            releaseAmount: 0,
            deadline: deadline
        });
        params.repayAmount = uint256(_position.borrowAmount).mulDivMillion(closeMillionth);
        params.releaseAmount =
            pairPoolManager.getAmountIn(_position.poolId, !_position.marginForOne, params.repayAmount);

        params.rawBorrowAmount = Math.mulDiv(_position.rawBorrowAmount, params.repayAmount, _position.borrowAmount);
        // call release
        pairPoolManager.release(params);

        _close(positionId, closeMillionth, pnlMinAmount, _position, marginCurrency, params);
    }

    function _getLiquidateStatus(PoolId poolId, bool marginForOne)
        internal
        view
        returns (LiquidateStatus memory liquidateStatus)
    {
        PoolStatus memory _status = pairPoolManager.getStatus(poolId);
        liquidateStatus.poolId = poolId;
        liquidateStatus.marginForOne = marginForOne;
        (liquidateStatus.borrowCurrency, liquidateStatus.marginCurrency) = marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        liquidateStatus.statusReserves = _status.getReservesX224();
        liquidateStatus.oracleReserves = checker.getOracleReserves(pairPoolManager, poolId);
    }

    function _liquidateProfit(PoolId poolId, Currency marginCurrency, uint256 marginAmount)
        internal
        returns (uint256 profit, uint256 protocolProfit)
    {
        (uint24 callerProfitMillion, uint24 protocolProfitMillion) = checker.getProfitMillions();

        if (callerProfitMillion > 0) {
            profit = marginAmount.mulDivMillion(callerProfitMillion);
            lendingPoolManager.withdraw(msg.sender, poolId, marginCurrency, profit);
        }
        if (protocolProfitMillion > 0) {
            address feeTo = pairPoolManager.marginFees().feeTo();
            if (feeTo != address(0)) {
                protocolProfit = marginAmount.mulDivMillion(protocolProfitMillion);
                lendingPoolManager.withdraw(feeTo, poolId, marginCurrency, protocolProfit);
            }
        }
    }

    function liquidateBurn(uint256 positionId, bytes calldata signature) external returns (uint256 profit) {
        require(checker.checkValidity(msg.sender, positionId, signature), "AUTH_ERROR");
        MarginPosition memory _position = _positions[positionId];
        BurnParams memory params = BurnParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            positionIds: new uint256[](1),
            signature: signature
        });
        params.positionIds[0] = positionId;
        return liquidateBurn(params);
    }

    function liquidateBurn(BurnParams memory params) public returns (uint256 profit) {
        require(checker.checkValidity(msg.sender, 0, params.signature), "AUTH_ERROR");
        MarginPosition[] memory inPositions = new MarginPosition[](params.positionIds.length);
        for (uint256 i = 0; i < params.positionIds.length; i++) {
            inPositions[i] = _positions[params.positionIds[i]];
        }
        LiquidateStatus memory liquidateStatus = _getLiquidateStatus(params.poolId, params.marginForOne);
        ReleaseParams memory releaseParams = ReleaseParams({
            poolId: params.poolId,
            marginForOne: params.marginForOne,
            payer: address(this),
            rawBorrowAmount: 0,
            releaseAmount: 0,
            repayAmount: 0,
            deadline: block.timestamp + 1000
        });
        {
            (bool[] memory liquidatedList, uint256[] memory borrowAmountList) =
                checker.checkLiquidate(pairPoolManager, liquidateStatus, inPositions);
            uint256 assetAmount;
            uint256 marginAmount;
            for (uint256 i = 0; i < params.positionIds.length; i++) {
                if (liquidatedList[i]) {
                    MarginPosition memory _position = inPositions[i];
                    marginAmount += _position.marginAmount;
                    assetAmount += _position.marginAmount + _position.marginTotal;
                    releaseParams.repayAmount += borrowAmountList[i];
                    releaseParams.rawBorrowAmount += _position.rawBorrowAmount;
                    emit Liquidate(
                        releaseParams.poolId,
                        msg.sender,
                        params.positionIds[i],
                        _position.marginAmount,
                        _position.marginTotal,
                        borrowAmountList[i],
                        liquidateStatus.oracleReserves,
                        liquidateStatus.statusReserves
                    );
                    _burnPosition(params.positionIds[i], BurnType.LIQUIDATE);
                }
            }
            if (marginAmount == 0) {
                return profit;
            }
            marginAmount =
                lendingPoolManager.computeRealAmount(params.poolId, liquidateStatus.marginCurrency, marginAmount);
            assetAmount =
                lendingPoolManager.computeRealAmount(params.poolId, liquidateStatus.marginCurrency, assetAmount);
            uint256 protocolProfit;
            (profit, protocolProfit) = _liquidateProfit(params.poolId, liquidateStatus.marginCurrency, marginAmount);
            releaseParams.releaseAmount = assetAmount - profit - protocolProfit;
        }
        if (releaseParams.releaseAmount > 0) {
            pairPoolManager.release(releaseParams);
        }
    }

    function liquidateCall(uint256 positionId, bytes calldata signature) external payable returns (uint256 profit) {
        require(checker.checkValidity(msg.sender, positionId, signature), "AUTH_ERROR");
        (bool liquidated, uint256 borrowAmount) = checker.checkLiquidate(address(this), positionId);
        if (!liquidated) {
            return profit;
        }
        MarginPosition memory _position = _positions[positionId];
        LiquidateStatus memory liquidateStatus = _getLiquidateStatus(_position.poolId, _position.marginForOne);
        uint256 sendValue = liquidateStatus.borrowCurrency.checkAmount(borrowAmount);
        ReleaseParams memory params = ReleaseParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: msg.sender,
            rawBorrowAmount: _position.rawBorrowAmount,
            repayAmount: borrowAmount,
            releaseAmount: 0,
            deadline: block.timestamp + 1000
        });
        pairPoolManager.release{value: sendValue}(params);
        profit = _position.marginAmount + _position.marginTotal;
        lendingPoolManager.withdraw(msg.sender, _position.poolId, liquidateStatus.marginCurrency, profit);
        if (msg.value > sendValue) {
            transferNative(msg.sender, msg.value - sendValue);
        }
        emit Liquidate(
            _position.poolId,
            msg.sender,
            positionId,
            _position.marginAmount,
            _position.marginTotal,
            borrowAmount,
            liquidateStatus.oracleReserves,
            liquidateStatus.statusReserves
        );
        _burnPosition(positionId, BurnType.LIQUIDATE);
    }

    /// @inheritdoc IMarginPositionManager
    function modify(uint256 positionId, int256 changeAmount) external payable nonReentrant {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        MarginPosition storage _position = _positions[positionId];
        PoolStatus memory _status = pairPoolManager.getStatus(_position.poolId);
        _updatePosition(_position, _status);
        Currency marginCurrency = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        uint256 amount = changeAmount < 0 ? uint256(-changeAmount) : uint256(changeAmount);
        if (changeAmount > 0) {
            uint256 sendValue = marginCurrency.checkAmount(amount);
            amount =
                lendingPoolManager.deposit{value: sendValue}(address(this), _position.poolId, marginCurrency, amount);
            _position.marginAmount += uint128(amount);
            if (msg.value > sendValue) transferNative(msg.sender, msg.value - sendValue);
        } else {
            require(amount <= checker.getMaxDecrease(pairPoolManager, _status, _position), "OVER_AMOUNT");
            lendingPoolManager.withdraw(msg.sender, _position.poolId, marginCurrency, amount);
            _position.marginAmount -= uint128(amount);
            if (msg.value > 0) transferNative(msg.sender, msg.value);
        }
        emit Modify(
            _position.poolId,
            msg.sender,
            positionId,
            _position.marginAmount,
            _position.marginTotal,
            _position.borrowAmount,
            changeAmount
        );
    }

    // ******************** INTERNAL CALL ********************

    function _getPosition(uint256 positionId) internal view returns (MarginPosition memory _position) {
        _position = _positions[positionId];
        if (_position.rateCumulativeLast > 0) {
            uint256 rateLast = pairPoolManager.marginFees().getBorrowRateCumulativeLast(
                address(pairPoolManager), _position.poolId, _position.marginForOne
            );
            _position.borrowAmount = _position.borrowAmount.increaseInterestCeil(_position.rateCumulativeLast, rateLast);
            _position.rateCumulativeLast = rateLast;
        }
    }

    function _updatePosition(MarginPosition storage _position, PoolStatus memory _status)
        internal
        returns (uint256 rateCumulativeLast)
    {
        rateCumulativeLast = _position.marginForOne ? _status.rate0CumulativeLast : _status.rate1CumulativeLast;
        _position.update(rateCumulativeLast);
    }
}
