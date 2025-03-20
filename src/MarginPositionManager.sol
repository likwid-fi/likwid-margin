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
import {PriceMath} from "./libraries/PriceMath.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";

contract MarginPositionManager is IMarginPositionManager, ERC721, Owned, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;
    using CurrencyExtLibrary for Currency;
    using UQ112x112 for *;
    using PriceMath for uint224;
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
        PoolStatus memory _status = pairPoolManager.setBalances(params.poolId);
        uint256 positionId;
        if (params.leverage > 0) {
            positionId = _marginPositionIds[params.poolId][params.marginForOne][params.recipient];
        } else {
            positionId = _borrowPositionIds[params.poolId][params.marginForOne][params.recipient];
        }
        // call margin
        MarginParamsVo memory paramsVo = MarginParamsVo({
            params: params,
            minMarginLevel: checker.minMarginLevel(),
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
        if (!checker.checkMinMarginLevel(pairPoolManager, paramsVo, _status)) {
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

    function _repay(
        uint256 positionId,
        PoolStatus memory _status,
        MarginPosition storage _position,
        ReleaseParams memory params,
        Currency marginCurrency
    ) internal returns (uint256 releaseAmount) {
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
        releaseAmount = realReleaseMargin + realReleaseTotal;
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
        PoolStatus memory _status = pairPoolManager.setBalances(_position.poolId);
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
            debtAmount: repayAmount,
            repayAmount: repayAmount,
            releaseAmount: 0,
            rawBorrowAmount: 0,
            deadline: deadline
        });
        params.rawBorrowAmount = uint256(_position.rawBorrowAmount) * repayAmount / _position.borrowAmount;
        uint256 sendValue = borrowCurrency.checkAmount(repayAmount);
        pairPoolManager.release{value: sendValue}(_status, params);
        if (msg.value > sendValue) {
            transferNative(msg.sender, msg.value - sendValue);
        }
        PoolId poolId = _position.poolId;
        // update position
        uint256 releaseAmount = _repay(positionId, _status, _position, params, marginCurrency);
        // withdraw original
        lendingPoolManager.withdraw(msg.sender, poolId, marginCurrency, releaseAmount);
    }

    function _close(
        uint256 positionId,
        uint256 releaseMargin,
        uint256 releaseTotal,
        int256 pnlMinAmount,
        MarginPosition storage _position,
        Currency marginCurrency,
        ReleaseParams memory params
    ) internal returns (uint256 profit) {
        int256 pnlAmount;
        uint256 releaseMarginReal =
            lendingPoolManager.computeRealAmount(_position.poolId, marginCurrency, releaseMargin);
        uint256 releaseTotalReal = lendingPoolManager.computeRealAmount(_position.poolId, marginCurrency, releaseTotal);
        {
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

        emit RepayClose(
            poolId,
            msg.sender,
            positionId,
            releaseMarginReal,
            releaseTotalReal,
            params.repayAmount,
            params.rawBorrowAmount,
            pnlAmount
        );
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
        PoolStatus memory _status = pairPoolManager.setBalances(_position.poolId);
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
        (params.releaseAmount,,) = pairPoolManager.marginFees().getAmountIn(
            address(pairPoolManager), _status, !_position.marginForOne, params.repayAmount
        );

        params.rawBorrowAmount = Math.mulDiv(_position.rawBorrowAmount, params.repayAmount, _position.borrowAmount);
        uint256 releaseMargin = uint256(_position.marginAmount).mulDivMillion(closeMillionth);
        uint256 releaseTotal = uint256(_position.marginTotal).mulDivMillion(closeMillionth);
        uint256 profit =
            _close(positionId, releaseMargin, releaseTotal, pnlMinAmount, _position, marginCurrency, params);
        // call release
        pairPoolManager.release(_status, params);
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
            lendingPoolManager.withdraw(msg.sender, params.poolId, marginCurrency, profit);
        }
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

    function liquidateBurn(uint256 positionId) external returns (uint256 profit) {
        require(checker.checkValidity(msg.sender, positionId), "AUTH_ERROR");
        (bool liquidated, uint256 borrowAmount) = checker.checkLiquidate(address(this), positionId);
        if (!liquidated) {
            return profit;
        }
        MarginPosition memory _position = _positions[positionId];
        PoolStatus memory _status = pairPoolManager.setBalances(_position.poolId);
        LiquidateStatus memory liquidateStatus =
            checker.getLiquidateStatus(address(pairPoolManager), _status, _position.marginForOne);
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

        {
            uint256 realMarginAmount = lendingPoolManager.computeRealAmount(
                _position.poolId, liquidateStatus.marginCurrency, _position.marginAmount
            );
            uint256 realMarginTotal = lendingPoolManager.computeRealAmount(
                _position.poolId, liquidateStatus.marginCurrency, _position.marginTotal
            );
            uint256 protocolProfit;
            (profit, protocolProfit) = _liquidateProfit(params.poolId, liquidateStatus.marginCurrency, realMarginAmount);
            params.releaseAmount = realMarginAmount + realMarginTotal - profit - protocolProfit;
            pairPoolManager.release(_status, params);
            emit Liquidate(
                _position.poolId,
                msg.sender,
                positionId,
                realMarginAmount,
                realMarginTotal,
                borrowAmount,
                liquidateStatus.oracleReserves,
                liquidateStatus.statusReserves
            );
        }
        _burnPosition(positionId, BurnType.LIQUIDATE);
    }

    function liquidateCall(uint256 positionId) external payable returns (uint256 profit) {
        require(checker.checkValidity(msg.sender, positionId), "AUTH_ERROR");
        (bool liquidated, uint256 borrowAmount) = checker.checkLiquidate(address(this), positionId);
        if (!liquidated) {
            return profit;
        }
        MarginPosition memory _position = _positions[positionId];
        PoolStatus memory _status = pairPoolManager.setBalances(_position.poolId);
        LiquidateStatus memory liquidateStatus =
            checker.getLiquidateStatus(address(pairPoolManager), _status, _position.marginForOne);
        uint256 sendValue = liquidateStatus.borrowCurrency.checkAmount(borrowAmount);
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
        pairPoolManager.release{value: sendValue}(_status, params);
        if (msg.value > sendValue) {
            transferNative(msg.sender, msg.value - sendValue);
        }
        {
            uint256 realMarginAmount = lendingPoolManager.computeRealAmount(
                _position.poolId, liquidateStatus.marginCurrency, _position.marginAmount
            );
            uint256 realMarginTotal = lendingPoolManager.computeRealAmount(
                _position.poolId, liquidateStatus.marginCurrency, _position.marginTotal
            );
            profit = realMarginAmount + realMarginTotal;
            lendingPoolManager.withdraw(msg.sender, _position.poolId, liquidateStatus.marginCurrency, profit);

            emit Liquidate(
                _position.poolId,
                msg.sender,
                positionId,
                realMarginAmount,
                realMarginTotal,
                borrowAmount,
                liquidateStatus.oracleReserves,
                liquidateStatus.statusReserves
            );
        }
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
