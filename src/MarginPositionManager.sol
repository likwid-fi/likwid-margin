// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
// Local
import {ReentrancyGuardTransient} from "./external/openzeppelin-contracts/ReentrancyGuardTransient.sol";
import {CurrencyExtLibrary} from "./libraries/CurrencyExtLibrary.sol";
import {CurrencyPoolLibrary} from "./libraries/CurrencyPoolLibrary.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {ILendingPoolManager} from "./interfaces/ILendingPoolManager.sol";
import {IPairMarginManager} from "./interfaces/IPairMarginManager.sol";
import {IMarginChecker} from "./interfaces/IMarginChecker.sol";
import {MarginPosition, MarginPositionVo} from "./types/MarginPosition.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {LiquidateStatus} from "./types/LiquidateStatus.sol";
import {ReleaseParams} from "./types/ReleaseParams.sol";
import {MarginParams, MarginParamsVo} from "./types/MarginParams.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";

contract MarginPositionManager is IMarginPositionManager, ERC721, Owned, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;
    using CurrencyPoolLibrary for Currency;
    using CurrencyExtLibrary for Currency;
    using UQ112x112 for *;
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

    IPairMarginManager public immutable pairPoolManager;
    IMarginChecker public checker;
    ILendingPoolManager private immutable lendingPoolManager;

    uint256 private nextId = 1;
    mapping(uint256 => MarginPosition) private _positions;
    mapping(PoolId => mapping(bool => mapping(address => uint256))) private _marginPositionIds;
    mapping(PoolId => mapping(bool => mapping(address => uint256))) private _borrowPositionIds;

    constructor(address initialOwner, IPairMarginManager _pairPoolManager, IMarginChecker _checker)
        Owned(initialOwner)
        ERC721("LIKWIDMarginPositionManager", "LMPM")
    {
        pairPoolManager = _pairPoolManager;
        lendingPoolManager = _pairPoolManager.lendingPoolManager();
        checker = _checker;
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    function _burnPosition(uint256 positionId, BurnType burnType) internal {
        MarginPosition memory _position = _positions[positionId];
        require(_position.rateCumulativeLast > 0, "ALREADY_BURNT");
        if (_position.marginTotal == 0) {
            delete _borrowPositionIds[_position.poolId][_position.marginForOne][ownerOf(positionId)];
        } else {
            delete _marginPositionIds[_position.poolId][_position.marginForOne][ownerOf(positionId)];
        }
        delete _positions[positionId];
        emit Burn(_position.poolId, msg.sender, positionId, uint8(burnType));
        _burn(positionId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        MarginPosition memory _position = _positions[tokenId];
        if (_position.rateCumulativeLast > 0) {
            if (_position.marginTotal == 0) {
                require(_borrowPositionIds[_position.poolId][_position.marginForOne][to] == 0, "ALREADY_EXISTS");
                delete _borrowPositionIds[_position.poolId][_position.marginForOne][from];
                _borrowPositionIds[_position.poolId][_position.marginForOne][to] = tokenId;
            } else {
                require(_marginPositionIds[_position.poolId][_position.marginForOne][to] == 0, "ALREADY_EXISTS");
                delete _marginPositionIds[_position.poolId][_position.marginForOne][from];
                _marginPositionIds[_position.poolId][_position.marginForOne][to] = tokenId;
            }
        }
        return from;
    }

    function _checkAmount(PoolStatus memory _status, Currency currency, uint256 amount)
        internal
        pure
        returns (bool v)
    {
        uint256 realAmount;
        if (_status.key.currency0 == currency) realAmount = _status.realReserve0 + _status.lendingRealReserve0;
        else realAmount = _status.realReserve1 + _status.lendingRealReserve1;
        v = realAmount > amount;
    }

    function _getReservesX224(PoolStatus memory status) internal pure returns (uint224 reserves) {
        reserves = (uint224(status.realReserve0 + status.mirrorReserve0) << 112)
            + uint224(status.realReserve1 + status.mirrorReserve1);
    }

    function _getTruncatedReservesX224(PoolStatus memory status) internal pure returns (uint224 reserves) {
        reserves = (uint224(status.truncatedReserve0) << 112) + uint224(status.truncatedReserve1);
    }

    /// @inheritdoc IMarginPositionManager
    function getPosition(uint256 positionId) external view returns (MarginPosition memory _position) {
        _position = checker.updatePosition(this, _positions[positionId]);
    }

    function getPositionId(PoolId poolId, bool marginForOne, address owner, bool isMargin)
        external
        view
        returns (uint256 _positionId)
    {
        if (isMargin) {
            _positionId = _marginPositionIds[poolId][marginForOne][owner];
        } else {
            _positionId = _borrowPositionIds[poolId][marginForOne][owner];
        }
    }

    /// @inheritdoc IMarginPositionManager
    function margin(MarginParams memory params) external payable ensure(params.deadline) returns (uint256, uint256) {
        PoolStatus memory _status = pairPoolManager.setBalances(msg.sender, params.poolId);
        uint256 positionId;
        if (params.leverage > 0) {
            positionId = _marginPositionIds[params.poolId][params.marginForOne][params.recipient];
        } else {
            positionId = _borrowPositionIds[params.poolId][params.marginForOne][params.recipient];
        }
        // call margin
        MarginParamsVo memory paramsVo = MarginParamsVo({
            params: params,
            minMarginLevel: checker.minBorrowLevel(),
            marginTotal: 0,
            marginCurrency: params.marginForOne ? _status.key.currency1 : _status.key.currency0
        });
        {
            uint256 sendValue = paramsVo.marginCurrency.checkAmount(params.marginAmount);
            paramsVo = pairPoolManager.margin{value: sendValue}(msg.sender, _status, paramsVo);
            params = paramsVo.params;
            if (msg.value > sendValue) transferNative(msg.sender, msg.value - sendValue);
        }
        if (params.borrowMaxAmount > 0 && params.borrowAmount > params.borrowMaxAmount) {
            revert InsufficientBorrowReceived();
        }
        if (!checker.checkMinMarginLevel(paramsVo, _status)) {
            revert InsufficientAmount(params.marginAmount);
        }
        if (positionId == 0) {
            _mint(params.recipient, (positionId = nextId++));
            emit Mint(params.poolId, msg.sender, params.recipient, positionId);
            uint256 rateCumulativeLast = params.marginForOne ? _status.rate0CumulativeLast : _status.rate1CumulativeLast;
            MarginPosition memory _position = MarginPosition({
                poolId: params.poolId,
                marginForOne: params.marginForOne,
                marginAmount: params.marginAmount.toUint112(),
                marginTotal: paramsVo.marginTotal.toUint112(),
                borrowAmount: params.borrowAmount.toUint112(),
                rawBorrowAmount: params.borrowAmount.toUint112(),
                rateCumulativeLast: rateCumulativeLast
            });
            if (paramsVo.marginTotal > 0) {
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
            if (paramsVo.marginTotal > 0) {
                _position.marginTotal += paramsVo.marginTotal.toUint112();
            }
            _position.rawBorrowAmount += params.borrowAmount.toUint112();
            _position.borrowAmount = _position.borrowAmount + params.borrowAmount.toUint112();
        }
        {
            uint256 marginAmount =
                lendingPoolManager.computeRealAmount(params.poolId, paramsVo.marginCurrency, params.marginAmount);
            uint256 marginTotal =
                lendingPoolManager.computeRealAmount(params.poolId, paramsVo.marginCurrency, paramsVo.marginTotal);
            emit Margin(
                params.poolId,
                params.recipient,
                positionId,
                marginAmount,
                marginTotal,
                params.borrowAmount,
                params.marginForOne
            );
        }

        return (positionId, params.borrowAmount);
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
        PoolStatus memory _status = pairPoolManager.setBalances(msg.sender, _position.poolId);
        (bool liquidated,) = checker.checkLiquidate(pairPoolManager, _status, _position);
        _updatePosition(_position, _status);
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
            debtAmount: repayAmount,
            repayAmount: repayAmount,
            releaseAmount: 0,
            rawBorrowAmount: 0,
            deadline: deadline
        });
        params.rawBorrowAmount = Math.mulDiv(_position.rawBorrowAmount, repayAmount, _position.borrowAmount);
        uint256 sendValue = borrowCurrency.checkAmount(repayAmount);
        pairPoolManager.release{value: sendValue}(msg.sender, _status, params);
        if (msg.value > sendValue) {
            transferNative(msg.sender, msg.value - sendValue);
        }
        PoolId poolId = _position.poolId;
        int256 pnlAmount = checker.estimatePNL(
            pairPoolManager, _status, _position, params.repayAmount.mulMillionDiv(_position.borrowAmount)
        );
        uint128 borrowAmount = _position.borrowAmount;
        uint256 releaseMargin = Math.mulDiv(_position.marginAmount, params.repayAmount, borrowAmount);
        uint256 releaseTotal = Math.mulDiv(_position.marginTotal, params.repayAmount, borrowAmount);
        uint256 realReleaseMargin =
            lendingPoolManager.computeRealAmount(_position.poolId, marginCurrency, releaseMargin);
        uint256 realReleaseTotal = lendingPoolManager.computeRealAmount(_position.poolId, marginCurrency, releaseTotal);
        emit RepayClose(
            _position.poolId,
            msg.sender,
            positionId,
            realReleaseMargin,
            realReleaseTotal,
            params.repayAmount,
            params.rawBorrowAmount,
            pnlAmount
        );
        _position.borrowAmount = borrowAmount - params.repayAmount.toUint112();
        if (_position.borrowAmount == 0) {
            _burnPosition(positionId, BurnType.CLOSE);
        } else {
            _position.marginAmount -= releaseMargin.toUint112();
            _position.marginTotal -= releaseTotal.toUint112();
            _position.rawBorrowAmount -= params.rawBorrowAmount.toUint112();
        }
        uint256 realAmount = realReleaseMargin + realReleaseTotal;
        if (_checkAmount(_status, marginCurrency, realAmount)) {
            // withdraw original
            lendingPoolManager.withdraw(msg.sender, poolId, marginCurrency, realAmount);
        } else {
            uint256 marginTokenId = marginCurrency.toTokenId(poolId);
            lendingPoolManager.transfer(msg.sender, marginTokenId, realAmount);
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
        require(_position.marginTotal > 0, "BORROW_DISABLE_CLOSE");
        PoolStatus memory _status = pairPoolManager.setBalances(msg.sender, _position.poolId);
        _updatePosition(_position, _status);
        Currency marginCurrency = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        ReleaseParams memory params = ReleaseParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: address(this),
            debtAmount: 0,
            repayAmount: 0,
            releaseAmount: 0,
            rawBorrowAmount: 0,
            deadline: deadline
        });
        params.repayAmount = params.debtAmount = uint256(_position.borrowAmount).mulDivMillion(closeMillionth);
        (params.releaseAmount,,) =
            pairPoolManager.statusManager().getAmountIn(_status, !_position.marginForOne, params.repayAmount);

        params.rawBorrowAmount = Math.mulDiv(_position.rawBorrowAmount, params.repayAmount, _position.borrowAmount);
        uint256 marginTokenId = marginCurrency.toTokenId(_position.poolId);
        uint256 accruesRatioX112 = lendingPoolManager.accruesRatioX112Of(marginTokenId);
        uint256 releaseMargin = uint256(_position.marginAmount).mulDivMillion(closeMillionth);
        uint256 releaseTotal = uint256(_position.marginTotal).mulDivMillion(closeMillionth);
        uint256 releaseMarginReal = uint256(releaseMargin).mulRatioX112(accruesRatioX112);
        uint256 releaseTotalReal = uint256(releaseTotal).mulRatioX112(accruesRatioX112);

        int256 pnlAmount = int256(releaseTotalReal) - int256(params.releaseAmount);
        uint256 profit;
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

        emit RepayClose(
            _position.poolId,
            msg.sender,
            positionId,
            releaseMarginReal,
            releaseTotalReal,
            params.repayAmount,
            params.rawBorrowAmount,
            pnlAmount
        );
        // call release
        pairPoolManager.release(msg.sender, _status, params);
        // update _position
        _position.borrowAmount = _position.borrowAmount - params.repayAmount.toUint112();

        if (_position.borrowAmount == 0) {
            _burnPosition(positionId, BurnType.CLOSE);
        } else {
            _position.marginAmount -= releaseMargin.toUint112();
            _position.marginTotal -= releaseTotal.toUint112();
            _position.rawBorrowAmount -= params.rawBorrowAmount.toUint112();
        }
        if (profit > 0) {
            if (_checkAmount(_status, marginCurrency, profit)) {
                // withdraw original
                lendingPoolManager.withdraw(msg.sender, params.poolId, marginCurrency, profit);
            } else {
                lendingPoolManager.transfer(msg.sender, marginTokenId, profit);
            }
        }
    }

    function liquidateBurn(uint256 positionId) external returns (uint256 profit, uint256 repayAmount) {
        require(checker.checkValidity(msg.sender, positionId), "AUTH_ERROR");
        MarginPosition memory _position = _positions[positionId];
        PoolStatus memory _status = pairPoolManager.setBalances(msg.sender, _position.poolId);
        (bool liquidated, uint256 borrowAmount) = checker.checkLiquidate(pairPoolManager, _status, _position);
        if (!liquidated) {
            return (profit, repayAmount);
        }
        Currency marginCurrency = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        uint256 statusReserves = _getReservesX224(_status);
        uint256 oracleReserves = _getTruncatedReservesX224(_status);
        ReleaseParams memory params = ReleaseParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: address(this),
            debtAmount: borrowAmount,
            repayAmount: 0,
            releaseAmount: 0,
            rawBorrowAmount: _position.rawBorrowAmount,
            deadline: block.timestamp + 1000
        });
        uint256 marginTokenId = marginCurrency.toTokenId(_position.poolId);
        uint256 accruesRatioX112 = lendingPoolManager.accruesRatioX112Of(marginTokenId);
        uint256 realMarginAmount = uint256(_position.marginAmount).mulRatioX112(accruesRatioX112);
        uint256 realMarginTotal = uint256(_position.marginTotal).mulRatioX112(accruesRatioX112);

        (uint24 callerProfitMillion, uint24 protocolProfitMillion) = checker.getProfitMillions();

        address feeTo;
        uint256 protocolProfit;
        uint256 assetsAmount = realMarginAmount + realMarginTotal;
        if (callerProfitMillion > 0) {
            profit = assetsAmount.mulDivMillion(callerProfitMillion);
        }
        if (protocolProfitMillion > 0) {
            feeTo = pairPoolManager.marginFees().feeTo();
            if (feeTo != address(0)) {
                protocolProfit = assetsAmount.mulDivMillion(protocolProfitMillion);
            }
        }
        if (profit > 0) {
            lendingPoolManager.transfer(msg.sender, marginTokenId, profit);
        }
        if (protocolProfit > 0) {
            lendingPoolManager.transfer(feeTo, marginTokenId, protocolProfit);
        }
        params.releaseAmount = assetsAmount - profit - protocolProfit;
        repayAmount = pairPoolManager.release(msg.sender, _status, params);
        _burnPosition(positionId, BurnType.LIQUIDATE);

        emit Liquidate(
            _position.poolId,
            msg.sender,
            positionId,
            realMarginAmount,
            realMarginTotal,
            borrowAmount,
            oracleReserves,
            statusReserves
        );
    }

    function liquidateCall(uint256 positionId) external payable returns (uint256 profit) {
        require(checker.checkValidity(msg.sender, positionId), "AUTH_ERROR");
        MarginPosition memory _position = _positions[positionId];
        // nonReentrant with pairPoolManager.release
        PoolStatus memory _status = pairPoolManager.setBalances(msg.sender, _position.poolId);
        (bool liquidated, uint256 borrowAmount) = checker.checkLiquidate(pairPoolManager, _status, _position);
        if (!liquidated) {
            return profit;
        }
        (Currency borrowCurrency, Currency marginCurrency) = _position.marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        uint256 statusReserves = _getReservesX224(_status);
        uint256 oracleReserves = _getTruncatedReservesX224(_status);
        uint256 sendValue = borrowCurrency.checkAmount(borrowAmount);
        ReleaseParams memory params = ReleaseParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: msg.sender,
            debtAmount: borrowAmount,
            repayAmount: borrowAmount,
            releaseAmount: 0,
            rawBorrowAmount: _position.rawBorrowAmount,
            deadline: block.timestamp + 1000
        });

        pairPoolManager.release{value: sendValue}(msg.sender, _status, params);
        if (msg.value > sendValue) {
            transferNative(msg.sender, msg.value - sendValue);
        }
        _burnPosition(positionId, BurnType.LIQUIDATE);

        uint256 marginTokenId = marginCurrency.toTokenId(_position.poolId);
        uint256 accruesRatioX112 = lendingPoolManager.accruesRatioX112Of(marginTokenId);
        uint256 realMarginAmount = uint256(_position.marginAmount).mulRatioX112(accruesRatioX112);
        uint256 realMarginTotal = uint256(_position.marginTotal).mulRatioX112(accruesRatioX112);
        profit = realMarginAmount + realMarginTotal;
        if (_checkAmount(_status, marginCurrency, profit)) {
            // withdraw original
            lendingPoolManager.withdraw(msg.sender, params.poolId, marginCurrency, profit);
        } else {
            lendingPoolManager.transfer(msg.sender, marginTokenId, profit);
        }

        emit Liquidate(
            _position.poolId,
            msg.sender,
            positionId,
            realMarginAmount,
            realMarginTotal,
            borrowAmount,
            oracleReserves,
            statusReserves
        );
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
            amount = lendingPoolManager.deposit{value: sendValue}(
                msg.sender, address(this), _position.poolId, marginCurrency, amount
            );
            _position.marginAmount += amount.toUint112();
            if (msg.value > sendValue) transferNative(msg.sender, msg.value - sendValue);
        } else {
            require(amount <= checker.getMaxDecrease(address(pairPoolManager), _status, _position), "OVER_AMOUNT");
            lendingPoolManager.withdraw(msg.sender, _position.poolId, marginCurrency, amount);
            _position.marginAmount -= amount.toUint112();
            if (msg.value > 0) transferNative(msg.sender, msg.value);
        }
        emit Modify(
            _position.poolId,
            msg.sender,
            positionId,
            lendingPoolManager.computeRealAmount(_position.poolId, marginCurrency, _position.marginAmount),
            lendingPoolManager.computeRealAmount(_position.poolId, marginCurrency, _position.marginTotal),
            _position.borrowAmount,
            changeAmount
        );
    }

    // ******************** INTERNAL CALL ********************

    function _updatePosition(MarginPosition storage _position, PoolStatus memory _status)
        internal
        returns (uint256 rateCumulativeLast)
    {
        rateCumulativeLast = _position.marginForOne ? _status.rate0CumulativeLast : _status.rate1CumulativeLast;
        _position.update(rateCumulativeLast);
    }

    function transferNative(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success, "TRANSFER_FAILED");
    }

    // ******************** OWNER CALL ********************
    function setMarginChecker(address _checker) external onlyOwner {
        checker = IMarginChecker(_checker);
    }
}
