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
import {ReentrancyGuardTransient} from "./external/openzeppelin-contracts/ReentrancyGuardTransient.sol";
import {CurrencyUtils} from "./libraries/CurrencyUtils.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IMarginChecker} from "./interfaces/IMarginChecker.sol";
import {MarginPosition, MarginPositionVo, BurnParams} from "./types/MarginPosition.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {LiquidateStatus} from "./types/LiquidateStatus.sol";
import {MarginParams, ReleaseParams} from "./types/MarginParams.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {TimeUtils} from "./libraries/TimeUtils.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";

contract MarginPositionManager is IMarginPositionManager, ERC721, Owned, ReentrancyGuardTransient {
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

    uint256 private _nextId = 1;
    uint24 public minMarginLevel = 1170000; // 117%
    IPairPoolManager public immutable pairPoolManager;
    IMarginChecker public checker;

    mapping(uint256 => MarginPosition) private _positions;
    mapping(PoolId => mapping(bool => mapping(address => uint256))) private _ownerPositionIds;

    constructor(address initialOwner, IPairPoolManager _pairPoolManager, IMarginChecker _checker)
        ERC721("LIKWIDMarginPositionManager", "LMPM")
        Owned(initialOwner)
    {
        pairPoolManager = _pairPoolManager;
        checker = _checker;
    }

    function _burnPosition(uint256 positionId, BurnType burnType) internal {
        // _burn(positionId);
        MarginPosition memory _position = _positions[positionId];
        require(_position.rateCumulativeLast > 0, "ALREADY_BURNT");
        delete _ownerPositionIds[_position.poolId][_position.marginForOne][ownerOf(positionId)];
        delete _positions[positionId];
        emit Burn(_position.poolId, msg.sender, positionId, uint8(burnType));
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        MarginPosition memory _position = _positions[tokenId];
        delete _ownerPositionIds[_position.poolId][_position.marginForOne][from];
        _ownerPositionIds[_position.poolId][_position.marginForOne][to] = tokenId;
        return from;
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    modifier onlyMargin() {
        require(msg.sender == address(pairPoolManager.poolManager()) || msg.sender == address(this), "ONLY_MARGIN");
        _;
    }

    function transferNative(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success, "TRANSFER_FAILED");
    }

    /// @inheritdoc IMarginPositionManager
    function getPairPool() external view returns (address _pairPoolManager) {
        _pairPoolManager = address(pairPoolManager);
    }

    /// @inheritdoc IMarginPositionManager
    function getPosition(uint256 positionId) public view returns (MarginPosition memory _position) {
        _position = _positions[positionId];
        if (_position.rateCumulativeLast > 0) {
            uint256 rateLast = pairPoolManager.marginFees().getBorrowRateCumulativeLast(
                address(pairPoolManager), _position.poolId, _position.marginForOne
            );
            _position.borrowAmount = _position.borrowAmount.increaseInterest(_position.rateCumulativeLast, rateLast);
            _position.rateCumulativeLast = rateLast;
        }
    }

    function _estimatePNL(MarginPosition memory _position, uint256 closeMillionth)
        internal
        view
        returns (int256 pnlAmount)
    {
        if (_position.borrowAmount == 0) {
            return 0;
        }
        uint256 repayAmount = uint256(_position.borrowAmount).mulDivMillion(closeMillionth);
        uint256 releaseAmount = pairPoolManager.getAmountIn(_position.poolId, !_position.marginForOne, repayAmount);
        uint256 releaseTotal = uint256(_position.marginTotal).mulDivMillion(closeMillionth);
        pnlAmount = int256(releaseTotal) - int256(releaseAmount);
    }

    /// @inheritdoc IMarginPositionManager
    function estimatePNL(uint256 positionId, uint256 closeMillionth) public view returns (int256 pnlAmount) {
        MarginPosition memory _position = getPosition(positionId);
        pnlAmount = _estimatePNL(_position, closeMillionth);
    }

    function getPositions(uint256[] calldata positionIds) external view returns (MarginPositionVo[] memory _position) {
        _position = new MarginPositionVo[](positionIds.length);
        for (uint256 i = 0; i < positionIds.length; i++) {
            _position[i].position = getPosition(positionIds[i]);
            _position[i].pnl = estimatePNL(positionIds[i], PerLibrary.ONE_MILLION);
        }
    }

    function getPositionId(PoolId poolId, bool marginForOne, address owner)
        external
        view
        returns (uint256 _positionId)
    {
        _positionId = _ownerPositionIds[poolId][marginForOne][owner];
    }

    function checkMinMarginLevel(MarginParams memory params, PoolStatus memory _status)
        internal
        view
        returns (bool valid)
    {
        (uint256 reserve0, uint256 reserve1) =
            (_status.realReserve0 + _status.mirrorReserve0, _status.realReserve1 + _status.mirrorReserve1);
        (uint256 reserveBorrow, uint256 reserveMargin) =
            params.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 debtAmount = reserveMargin * params.borrowAmount / reserveBorrow;
        valid = params.marginAmount + params.marginTotal >= debtAmount.mulDivMillion(minMarginLevel);
    }

    function checkAmount(Currency currency, address payer, address recipient, uint256 amount)
        internal
        returns (bool valid)
    {
        if (currency.isAddressZero()) {
            valid = msg.value >= amount;
        } else {
            if (payer != address(this)) {
                valid = IERC20Minimal(Currency.unwrap(currency)).allowance(payer, recipient) >= amount;
            } else {
                valid = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this)) >= amount;
            }
        }
    }

    /// @inheritdoc IMarginPositionManager
    function margin(MarginParams memory params) external payable ensure(params.deadline) returns (uint256, uint256) {
        PoolStatus memory _status = pairPoolManager.getStatus(params.poolId);
        Currency marginToken = params.marginForOne ? _status.key.currency1 : _status.key.currency0;
        if (!checkAmount(marginToken, msg.sender, address(this), params.marginAmount)) {
            revert InsufficientAmount(params.marginAmount);
        }
        bool success = marginToken.transfer(msg.sender, address(this), params.marginAmount);
        if (!success) revert MarginTransferFailed(params.marginAmount);
        uint256 positionId = _ownerPositionIds[params.poolId][params.marginForOne][params.recipient];
        params = pairPoolManager.margin(params);
        uint256 rateLast = params.marginForOne ? _status.rate0CumulativeLast : _status.rate1CumulativeLast;
        if (params.borrowMaxAmount > 0 && params.borrowAmount > params.borrowMaxAmount) {
            revert InsufficientBorrowReceived();
        }
        if (!checkMinMarginLevel(params, _status)) revert InsufficientAmount(params.marginAmount);
        if (positionId == 0) {
            _mint(params.recipient, (positionId = _nextId++));
            emit Mint(params.poolId, msg.sender, params.recipient, positionId);
            MarginPosition memory _position = MarginPosition({
                poolId: params.poolId,
                marginForOne: params.marginForOne,
                marginAmount: params.marginAmount.toUint112(),
                marginTotal: params.marginTotal.toUint112(),
                borrowAmount: params.borrowAmount.toUint112(),
                rawBorrowAmount: params.borrowAmount.toUint112(),
                rateCumulativeLast: rateLast
            });
            (bool liquidated,) = checker.checkLiquidate(_position, address(pairPoolManager));
            if (liquidated) revert PositionLiquidated();
            _ownerPositionIds[params.poolId][params.marginForOne][params.recipient] = positionId;
            _positions[positionId] = _position;
        } else {
            MarginPosition storage _position = _positions[positionId];
            _position.update(rateLast);
            _position.marginAmount += params.marginAmount.toUint112();
            _position.marginTotal += params.marginTotal.toUint112();
            _position.rawBorrowAmount += params.borrowAmount.toUint112();
            _position.borrowAmount = _position.borrowAmount + params.borrowAmount.toUint112();
            (bool liquidated,) = checker.checkLiquidate(_position, address(pairPoolManager));
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
        return (positionId, params.borrowAmount);
    }

    function _releasePosition(
        uint256 positionId,
        Currency marginToken,
        uint256 repayAmount,
        uint256 borrowAmount,
        uint256 repayRawAmount,
        int256 pnlAmount,
        uint256 rateLast
    ) internal {
        MarginPosition storage _position = _positions[positionId];
        (bool liquidated,) = checker.checkLiquidate(_position, address(pairPoolManager));
        if (liquidated) revert PositionLiquidated();
        // update position
        _position.borrowAmount = uint128(borrowAmount - repayAmount);
        uint256 releaseMargin = uint256(_position.marginAmount) * repayAmount / borrowAmount;
        uint256 releaseTotal = uint256(_position.marginTotal) * repayAmount / borrowAmount;
        bool success = marginToken.transfer(address(this), msg.sender, releaseMargin + releaseTotal);
        require(success, "RELEASE_TRANSFER_ERR");
        emit RepayClose(
            _position.poolId,
            msg.sender,
            positionId,
            releaseMargin,
            releaseTotal,
            repayAmount,
            repayRawAmount,
            pnlAmount
        );
        if (_position.borrowAmount == 0) {
            _burnPosition(positionId, BurnType.CLOSE);
        } else {
            _position.marginAmount -= uint128(releaseMargin);
            _position.marginTotal -= uint128(releaseTotal);
            _position.rawBorrowAmount -= uint128(repayRawAmount);
            _position.rateCumulativeLast = rateLast;
        }
    }

    /// @inheritdoc IMarginPositionManager
    function repay(uint256 positionId, uint256 repayAmount, uint256 deadline)
        external
        payable
        nonReentrant
        ensure(deadline)
    {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        MarginPosition memory _position = getPosition(positionId);
        PoolStatus memory _status = pairPoolManager.getStatus(_position.poolId);
        (Currency borrowToken, Currency marginToken) = _position.marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        if (!checkAmount(borrowToken, msg.sender, address(pairPoolManager), repayAmount)) {
            revert InsufficientAmount(repayAmount);
        }
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
        int256 pnlAmount = _estimatePNL(_position, repayAmount.mulMillionDiv(_position.borrowAmount));
        uint256 sendValue = Math.min(repayAmount, msg.value);
        pairPoolManager.release{value: sendValue}(params);
        _releasePosition(
            positionId,
            marginToken,
            repayAmount,
            _position.borrowAmount,
            params.rawBorrowAmount,
            pnlAmount,
            _position.rateCumulativeLast
        );
        if (msg.value > sendValue) {
            transferNative(msg.sender, msg.value - sendValue);
        }
    }

    function _closePosition(
        uint256 positionId,
        uint256 releaseMargin,
        uint256 releaseTotal,
        uint256 repayAmount,
        uint256 borrowAmount,
        uint256 repayRawAmount,
        uint256 rateLast
    ) internal {
        // update position
        MarginPosition storage sPosition = _positions[positionId];
        sPosition.borrowAmount = uint128(borrowAmount - repayAmount);

        if (sPosition.borrowAmount == 0) {
            _burnPosition(positionId, BurnType.CLOSE);
        } else {
            sPosition.marginAmount -= uint128(releaseMargin);
            sPosition.marginTotal -= uint128(releaseTotal);
            sPosition.rawBorrowAmount -= uint128(repayRawAmount);
            sPosition.rateCumulativeLast = rateLast;
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
        MarginPosition memory _position = getPosition(positionId);
        PoolStatus memory _status = pairPoolManager.getStatus(_position.poolId);
        Currency marginToken = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
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
        uint256 releaseMargin = uint256(_position.marginAmount).mulDivMillion(closeMillionth);
        uint256 releaseTotal = uint256(_position.marginTotal).mulDivMillion(closeMillionth);
        int256 pnlAmount = int256(releaseTotal) - int256(params.releaseAmount);
        require(pnlMinAmount == 0 || pnlMinAmount <= pnlAmount, "InsufficientOutputReceived");
        if (pnlAmount >= 0) {
            if (pnlAmount > 0) {
                marginToken.transfer(address(this), msg.sender, uint256(pnlAmount) + releaseMargin);
            }
        } else {
            if (uint256(-pnlAmount) < releaseMargin) {
                marginToken.transfer(address(this), msg.sender, releaseMargin - uint256(-pnlAmount));
            } else if (uint256(-pnlAmount) < uint256(_position.marginAmount)) {
                releaseMargin = uint256(-pnlAmount);
            } else {
                // liquidated
                revert PositionLiquidated();
            }
        }
        params.rawBorrowAmount = uint256(_position.rawBorrowAmount) * params.repayAmount / _position.borrowAmount;
        if (marginToken == CurrencyLibrary.ADDRESS_ZERO) {
            pairPoolManager.release{value: params.releaseAmount}(params);
        } else {
            bool success = marginToken.approve(address(pairPoolManager), params.releaseAmount);
            require(success, "APPROVE_ERR");
            pairPoolManager.release(params);
        }
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
        _closePosition(
            positionId,
            releaseMargin,
            releaseTotal,
            params.repayAmount,
            _position.borrowAmount,
            params.rawBorrowAmount,
            _position.rateCumulativeLast
        );
    }

    function _getLiquidateStatus(PoolId poolId, bool marginForOne)
        internal
        view
        returns (LiquidateStatus memory liquidateStatus)
    {
        PoolStatus memory _status = pairPoolManager.getStatus(poolId);
        (liquidateStatus.borrowCurrency, liquidateStatus.marginCurrency) = marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        liquidateStatus.statusReserves = _status.getReservesX224();
        liquidateStatus.oracleReserves = checker.getOracleReserves(poolId, address(pairPoolManager));
    }

    function _liquidateProfit(Currency marginToken, uint256 marginAmount)
        internal
        returns (uint256 profit, uint256 protocolProfit)
    {
        (uint24 callerProfitMillion, uint24 protocolProfitMillion) = checker.getProfitMillions();

        if (callerProfitMillion > 0) {
            profit = marginAmount.mulDivMillion(callerProfitMillion);
            marginToken.transfer(address(this), msg.sender, profit);
        }
        if (protocolProfitMillion > 0) {
            address feeTo = pairPoolManager.marginFees().feeTo();
            if (feeTo != address(0)) {
                protocolProfit = marginAmount.mulDivMillion(protocolProfitMillion);
                marginToken.transfer(address(this), feeTo, protocolProfit);
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
        (bool[] memory liquidatedList, uint256[] memory borrowAmountList) =
            checker.checkLiquidate(params.poolId, params.marginForOne, address(pairPoolManager), inPositions);
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
            uint256 assetAmount;
            uint256 marginAmount;
            for (uint256 i = 0; i < params.positionIds.length; i++) {
                if (liquidatedList[i]) {
                    uint256 positionId = params.positionIds[i];
                    uint256 borrowAmount = borrowAmountList[i];
                    MarginPosition memory _position = inPositions[i];
                    marginAmount += _position.marginAmount;
                    assetAmount += _position.marginAmount + _position.marginTotal;
                    releaseParams.repayAmount += borrowAmount;
                    releaseParams.rawBorrowAmount += _position.rawBorrowAmount;
                    emit Liquidate(
                        releaseParams.poolId,
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
            }
            if (marginAmount == 0) {
                return profit;
            }
            uint256 protocolProfit;
            (profit, protocolProfit) = _liquidateProfit(liquidateStatus.marginCurrency, marginAmount);
            releaseParams.releaseAmount = assetAmount - profit - protocolProfit;
        }
        if (releaseParams.releaseAmount > 0) {
            uint256 liquidateValue;
            if (liquidateStatus.marginCurrency == CurrencyLibrary.ADDRESS_ZERO) {
                liquidateValue = releaseParams.releaseAmount;
            } else {
                bool success =
                    liquidateStatus.marginCurrency.approve(address(pairPoolManager), releaseParams.releaseAmount);
                require(success, "APPROVE_ERR");
            }
            pairPoolManager.release{value: liquidateValue}(releaseParams);
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
        if (!checkAmount(liquidateStatus.borrowCurrency, msg.sender, address(pairPoolManager), borrowAmount)) {
            revert InsufficientAmount(borrowAmount);
        }
        uint256 liquidateValue;
        if (liquidateStatus.borrowCurrency == CurrencyLibrary.ADDRESS_ZERO) {
            liquidateValue = borrowAmount;
        }
        ReleaseParams memory params = ReleaseParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: msg.sender,
            rawBorrowAmount: _position.rawBorrowAmount,
            repayAmount: borrowAmount,
            releaseAmount: 0,
            deadline: block.timestamp + 1000
        });
        pairPoolManager.release{value: liquidateValue}(params);
        profit = _position.marginAmount + _position.marginTotal;
        liquidateStatus.marginCurrency.transfer(address(this), msg.sender, profit);
        if (msg.value > liquidateValue) {
            transferNative(msg.sender, msg.value - liquidateValue);
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
    function getMaxDecrease(uint256 positionId) external view returns (uint256 maxAmount) {
        MarginPosition memory _position = getPosition(positionId);
        maxAmount = checker.getMaxDecrease(_position, address(pairPoolManager));
    }

    /// @inheritdoc IMarginPositionManager
    function modify(uint256 positionId, int256 changeAmount) external payable nonReentrant {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        MarginPosition storage _position = _positions[positionId];
        PoolStatus memory _status = pairPoolManager.getStatus(_position.poolId);
        if (_position.rateCumulativeLast > 0) {
            uint256 rateLast = _position.marginForOne ? _status.rate0CumulativeLast : _status.rate1CumulativeLast;
            _position.borrowAmount = _position.borrowAmount.increaseInterest(_position.rateCumulativeLast, rateLast);
            _position.rateCumulativeLast = rateLast;
        }
        Currency marginToken = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        uint256 amount = changeAmount < 0 ? uint256(-changeAmount) : uint256(changeAmount);
        if (!checkAmount(marginToken, msg.sender, address(this), amount)) {
            revert InsufficientAmount(amount);
        }
        if (changeAmount > 0) {
            bool b = marginToken.transfer(msg.sender, address(this), amount);
            require(b, "TRANSFER_ERR");
            _position.marginAmount += uint128(amount);
        } else {
            require(amount <= checker.getMaxDecrease(_position, address(pairPoolManager)), "OVER_AMOUNT");
            bool b = marginToken.transfer(address(this), msg.sender, amount);
            require(b, "TRANSFER_ERR");
            _position.marginAmount -= uint128(amount);
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

    receive() external payable onlyMargin {}

    // ******************** OWNER CALL ********************
    function setMinMarginLevel(uint24 _minMarginLevel) external onlyOwner {
        minMarginLevel = _minMarginLevel;
    }

    function setMarginChecker(address _checker) external onlyOwner {
        checker = IMarginChecker(_checker);
    }
}
