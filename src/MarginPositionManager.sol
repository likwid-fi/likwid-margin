// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
// Local
import {CurrencyUtils} from "./libraries/CurrencyUtils.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {IMarginHookManager} from "./interfaces/IMarginHookManager.sol";
import {IMarginChecker} from "./interfaces/IMarginChecker.sol";
import {MarginPosition, MarginPositionVo, BurnParams} from "./types/MarginPosition.sol";
import {HookStatus} from "./types/HookStatus.sol";
import {MarginParams, ReleaseParams} from "./types/MarginParams.sol";
import {Math} from "./libraries/Math.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {TimeUtils} from "./libraries/TimeUtils.sol";

contract MarginPositionManager is IMarginPositionManager, ERC721, Owned {
    using CurrencyUtils for Currency;
    using CurrencyLibrary for Currency;
    using UQ112x112 for uint224;
    using PriceMath for uint224;
    using TimeUtils for uint32;

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
    event Repay(
        PoolId indexed poolId,
        address indexed sender,
        uint256 positionId,
        uint256 releaseMarginAmount,
        uint256 releaseMarginTotal,
        uint256 repayRawAmount,
        int256 pnlAmount
    );
    event Close(
        PoolId indexed poolId,
        address indexed sender,
        uint256 positionId,
        uint256 releaseMarginAmount,
        uint256 releaseMarginTotal,
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
        uint256 borrowAmount
    );

    enum BurnType {
        CLOSE,
        LIQUIDATE
    }

    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 public constant ONE_BILLION = 10 ** 9;
    uint256 public constant YEAR_SECONDS = 365 * 24 * 3600;
    uint256 private _nextId = 1;
    uint24 public minMarginLevel = 1170000; // 117%
    IMarginHookManager private hook;
    IMarginChecker public checker;

    mapping(uint256 => MarginPosition) private _positions;
    mapping(address => uint256) private _hookPositions;
    mapping(PoolId => mapping(bool => mapping(address => uint256))) private _borrowPositions;

    constructor(address initialOwner, IMarginChecker _checker)
        ERC721("LIKWIDMarginPositionManager", "LMPM")
        Owned(initialOwner)
    {
        checker = _checker;
    }

    function _burnPosition(uint256 positionId, BurnType burnType) internal {
        // _burn(positionId);
        MarginPosition memory _position = _positions[positionId];
        delete _borrowPositions[_position.poolId][_position.marginForOne][ownerOf(positionId)];
        delete _positions[positionId];
        emit Burn(_position.poolId, msg.sender, positionId, uint8(burnType));
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    modifier onlyMargin() {
        require(msg.sender == address(hook.poolManager()) || msg.sender == address(this), "ONLY_MARGIN");
        _;
    }

    function transferNative(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success, "TRANSFER_FAILED");
    }

    function setHook(address _hook) external onlyOwner {
        hook = IMarginHookManager(_hook);
    }

    function getHook() external view returns (address _hook) {
        _hook = address(hook);
    }

    function setMinMarginLevel(uint24 _minMarginLevel) external onlyOwner {
        minMarginLevel = _minMarginLevel;
    }

    function setMarginChecker(address _checker) external onlyOwner {
        checker = IMarginChecker(_checker);
    }

    function getPosition(uint256 positionId) public view returns (MarginPosition memory _position) {
        _position = _positions[positionId];
        if (_position.rateCumulativeLast > 0) {
            uint256 rateLast =
                hook.marginFees().getBorrowRateCumulativeLast(address(hook), _position.poolId, _position.marginForOne);
            _position.borrowAmount = uint128(uint256(_position.borrowAmount) * rateLast / _position.rateCumulativeLast);
            _position.rateCumulativeLast = rateLast;
        }
    }

    function _estimatePNL(MarginPosition memory _position, uint256 repayMillionth)
        internal
        view
        returns (int256 pnlAmount)
    {
        if (_position.borrowAmount == 0) {
            return 0;
        }
        uint256 repayAmount = uint256(_position.borrowAmount) * repayMillionth / ONE_MILLION;
        uint256 releaseAmount = hook.getAmountIn(_position.poolId, !_position.marginForOne, repayAmount);
        uint256 releaseTotal = uint256(_position.marginTotal) * repayMillionth / ONE_MILLION;
        pnlAmount = int256(releaseTotal) - int256(releaseAmount);
    }

    function estimatePNL(uint256 positionId, uint256 repayMillionth) public view returns (int256 pnlAmount) {
        MarginPosition memory _position = getPosition(positionId);
        pnlAmount = _estimatePNL(_position, repayMillionth);
    }

    function getPositions(uint256[] calldata positionIds) external view returns (MarginPositionVo[] memory _position) {
        _position = new MarginPositionVo[](positionIds.length);
        for (uint256 i = 0; i < positionIds.length; i++) {
            _position[i].position = getPosition(positionIds[i]);
            _position[i].pnl = estimatePNL(positionIds[i], ONE_MILLION);
        }
    }

    function getPositionId(PoolId poolId, bool marginForOne, address owner)
        external
        view
        returns (uint256 _positionId)
    {
        _positionId = _borrowPositions[poolId][marginForOne][owner];
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

    function checkMinMarginLevel(MarginParams memory params, HookStatus memory _status)
        internal
        view
        returns (bool valid)
    {
        (uint256 reserve0, uint256 reserve1) =
            (_status.realReserve0 + _status.mirrorReserve0, _status.realReserve1 + _status.mirrorReserve1);
        (uint256 reserveBorrow, uint256 reserveMargin) =
            params.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 amountDebt = reserveMargin * params.borrowAmount / reserveBorrow;
        valid = params.marginAmount + params.marginTotal >= amountDebt * minMarginLevel / ONE_MILLION;
    }

    function getMarginTotal(PoolId poolId, bool marginForOne, uint24 leverage, uint256 marginAmount)
        external
        view
        returns (uint256 marginWithoutFee, uint256 borrowAmount)
    {
        (, uint24 marginFee) = hook.marginFees().getPoolFees(address(hook), poolId);
        uint256 marginTotal = marginAmount * leverage;
        borrowAmount = hook.getAmountIn(poolId, marginForOne, marginTotal);
        marginWithoutFee = marginTotal * (ONE_MILLION - marginFee) / ONE_MILLION;
    }

    function getMarginMax(PoolId poolId, bool marginForOne, uint24 leverage)
        external
        view
        returns (uint256 marginMax, uint256 borrowAmount)
    {
        HookStatus memory status = hook.getStatus(poolId);
        (uint256 _totalSupply, uint256 retainSupply0, uint256 retainSupply1) =
            hook.marginLiquidity().getPoolSupplies(address(hook), poolId);
        uint256 marginReserve0 = (_totalSupply - retainSupply0) * status.realReserve0 / _totalSupply;
        uint256 marginReserve1 = (_totalSupply - retainSupply1) * status.realReserve1 / _totalSupply;
        uint256 marginMaxTotal = (marginForOne ? marginReserve1 : marginReserve0);
        if (marginMaxTotal > 1000) {
            (uint256 reserve0, uint256 reserve1) = hook.getReserves(poolId);
            uint256 marginMaxReserve = (marginForOne ? reserve1 : reserve0);
            uint24 part = 380;
            if (leverage == 2) {
                part = 200;
            } else if (leverage == 3) {
                part = 100;
            } else if (leverage == 4) {
                part = 40;
            } else if (leverage == 5) {
                part = 9;
            }
            marginMaxReserve = marginMaxReserve * part / 1000;
            marginMaxTotal = Math.min(marginMaxTotal, marginMaxReserve);
            marginMaxTotal -= 1000;
        }
        borrowAmount = hook.getAmountIn(poolId, marginForOne, marginMaxTotal);
        marginMax = marginMaxTotal / leverage;
    }

    function margin(MarginParams memory params) external payable ensure(params.deadline) returns (uint256, uint256) {
        HookStatus memory _status = hook.getStatus(params.poolId);
        Currency marginToken = params.marginForOne ? _status.key.currency1 : _status.key.currency0;
        if (!checkAmount(marginToken, msg.sender, address(this), params.marginAmount)) {
            revert InsufficientAmount(params.marginAmount);
        }
        bool success = marginToken.transfer(msg.sender, address(this), params.marginAmount);
        if (!success) revert MarginTransferFailed(params.marginAmount);
        uint256 positionId = _borrowPositions[params.poolId][params.marginForOne][params.recipient];
        params = hook.margin(params);
        uint256 rateLast = hook.marginFees().getBorrowRateCumulativeLast(_status, params.marginForOne);
        if (params.borrowAmount < params.borrowMinAmount) revert InsufficientBorrowReceived();
        if (!checkMinMarginLevel(params, _status)) revert InsufficientAmount(params.marginAmount);
        if (positionId == 0) {
            _mint(params.recipient, (positionId = _nextId++));
            emit Mint(params.poolId, msg.sender, params.recipient, positionId);
            MarginPosition memory _position = MarginPosition({
                poolId: params.poolId,
                marginForOne: params.marginForOne,
                marginAmount: uint128(params.marginAmount),
                marginTotal: uint128(params.marginTotal),
                borrowAmount: uint128(params.borrowAmount),
                rawBorrowAmount: uint128(params.borrowAmount),
                rateCumulativeLast: rateLast
            });
            (bool liquidated,) = checker.checkLiquidate(_position, address(hook));
            require(!liquidated, "liquidated");
            _borrowPositions[params.poolId][params.marginForOne][params.recipient] = positionId;
            _positions[positionId] = _position;
        } else {
            MarginPosition storage _position = _positions[positionId];
            uint256 borrowAmount = uint256(_position.borrowAmount) * rateLast / _position.rateCumulativeLast;
            _position.marginAmount += uint128(params.marginAmount);
            _position.marginTotal += uint128(params.marginTotal);
            _position.rawBorrowAmount += uint128(params.borrowAmount);
            _position.borrowAmount = uint128(borrowAmount + params.borrowAmount);
            _position.rateCumulativeLast = rateLast;
            (bool liquidated,) = checker.checkLiquidate(_position, address(hook));
            require(!liquidated, "liquidated");
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

    function release(
        uint256 positionId,
        Currency marginToken,
        uint256 repayAmount,
        uint256 borrowAmount,
        uint256 repayRawAmount,
        int256 pnlAmount,
        uint256 rateLast
    ) internal {
        MarginPosition storage _position = _positions[positionId];
        (bool liquidated,) = checker.checkLiquidate(_position, address(hook));
        if (liquidated) revert PositionLiquidated();
        // update position
        _position.borrowAmount = uint128(borrowAmount - repayAmount);
        uint256 releaseMargin = uint256(_position.marginAmount) * repayAmount / borrowAmount;
        uint256 releaseTotal = uint256(_position.marginTotal) * repayAmount / borrowAmount;
        bool success = marginToken.transfer(address(this), msg.sender, releaseMargin + releaseTotal);
        require(success, "RELEASE_TRANSFER_ERR");
        emit Repay(_position.poolId, msg.sender, positionId, releaseMargin, releaseTotal, repayRawAmount, pnlAmount);
        if (_position.borrowAmount == 0) {
            _burnPosition(positionId, BurnType.CLOSE);
        } else {
            _position.marginAmount -= uint128(releaseMargin);
            _position.marginTotal -= uint128(releaseTotal);
            _position.rawBorrowAmount -= uint128(repayRawAmount);
            _position.rateCumulativeLast = rateLast;
        }
    }

    function repay(uint256 positionId, uint256 repayAmount, uint256 deadline) external payable ensure(deadline) {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        MarginPosition memory _position = getPosition(positionId);
        HookStatus memory _status = hook.getStatus(_position.poolId);
        (Currency borrowToken, Currency marginToken) = _position.marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        if (!checkAmount(borrowToken, msg.sender, address(hook), repayAmount)) {
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
        int256 pnlAmount = _estimatePNL(_position, repayAmount * ONE_MILLION / _position.borrowAmount);
        uint256 sendValue = Math.min(repayAmount, msg.value);
        hook.release{value: sendValue}(params);
        release(
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

    function close(
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

    function close(uint256 positionId, uint256 repayMillionth, int256 pnlMinAmount, uint256 deadline)
        external
        payable
        ensure(deadline)
    {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        require(repayMillionth <= ONE_MILLION, "MILLIONTH_ERROR");
        MarginPosition memory _position = getPosition(positionId);
        HookStatus memory _status = hook.getStatus(_position.poolId);
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
        params.repayAmount = uint256(_position.borrowAmount) * repayMillionth / ONE_MILLION;
        params.releaseAmount = hook.getAmountIn(_position.poolId, !_position.marginForOne, params.repayAmount);
        uint256 releaseMargin = uint256(_position.marginAmount) * repayMillionth / ONE_MILLION;
        uint256 releaseTotal = uint256(_position.marginTotal) * repayMillionth / ONE_MILLION;
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
            hook.release{value: params.releaseAmount}(params);
        } else {
            bool success = marginToken.approve(address(hook), params.releaseAmount);
            require(success, "APPROVE_ERR");
            hook.release(params);
        }
        emit Close(
            _position.poolId, msg.sender, positionId, releaseMargin, releaseTotal, params.rawBorrowAmount, pnlAmount
        );
        close(
            positionId,
            releaseMargin,
            releaseTotal,
            params.repayAmount,
            _position.borrowAmount,
            params.rawBorrowAmount,
            _position.rateCumulativeLast
        );
    }

    function liquidateBurn(uint256 positionId, bytes calldata signature) external returns (uint256 profit) {
        require(checker.checkLiquidate(msg.sender, positionId, signature), "AUTH_ERROR");
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
        require(checker.checkLiquidate(msg.sender, 0, params.signature), "AUTH_ERROR");
        MarginPosition[] memory inPositions = new MarginPosition[](params.positionIds.length);
        for (uint256 i = 0; i < params.positionIds.length; i++) {
            inPositions[i] = _positions[params.positionIds[i]];
        }
        (bool[] memory liquidatedList, uint256[] memory amountDebtList) =
            checker.checkLiquidate(params.poolId, params.marginForOne, address(hook), inPositions);

        uint256 releaseAmount;
        uint256 rawBorrowAmount;
        uint256 borrowAmount;
        uint256 liquidateValue;
        {
            for (uint256 i = 0; i < params.positionIds.length; i++) {
                if (liquidatedList[i]) {
                    uint256 positionId = params.positionIds[i];
                    MarginPosition memory _position = inPositions[i];
                    uint256 assetAmount = _position.marginAmount + _position.marginTotal;
                    uint256 _releaseAmount = Math.min(amountDebtList[i], assetAmount);
                    releaseAmount += _releaseAmount;
                    rawBorrowAmount += _position.rawBorrowAmount;
                    borrowAmount += _position.borrowAmount;
                    profit = assetAmount - _releaseAmount;
                    emit Liquidate(
                        params.poolId,
                        msg.sender,
                        positionId,
                        _position.marginAmount,
                        _position.marginTotal,
                        _position.borrowAmount
                    );
                    _burnPosition(positionId, BurnType.LIQUIDATE);
                }
            }
            HookStatus memory _status = hook.getStatus(params.poolId);
            Currency marginToken = params.marginForOne ? _status.key.currency1 : _status.key.currency0;
            if (marginToken == CurrencyLibrary.ADDRESS_ZERO) {
                liquidateValue = releaseAmount;
            } else {
                bool success = marginToken.approve(address(hook), releaseAmount);
                require(success, "APPROVE_ERR");
            }
            if (profit > 0) {
                marginToken.transfer(address(this), msg.sender, profit);
            }
        }
        if (releaseAmount > 0) {
            ReleaseParams memory releaseParams = ReleaseParams({
                poolId: params.poolId,
                marginForOne: params.marginForOne,
                payer: address(this),
                rawBorrowAmount: rawBorrowAmount,
                releaseAmount: releaseAmount,
                repayAmount: borrowAmount,
                deadline: block.timestamp + 1000
            });
            hook.release{value: liquidateValue}(releaseParams);
        }
    }

    function liquidateCall(uint256 positionId, bytes calldata signature) external payable returns (uint256 profit) {
        require(checker.checkLiquidate(msg.sender, positionId, signature), "AUTH_ERROR");
        (bool liquidated,) = checker.checkLiquidate(address(this), positionId);
        if (!liquidated) {
            return profit;
        }
        MarginPosition memory _position = getPosition(positionId);
        HookStatus memory _status = hook.getStatus(_position.poolId);
        (Currency borrowToken, Currency marginToken) = _position.marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        uint256 borrowAmount = uint256(_position.borrowAmount);
        if (!checkAmount(borrowToken, msg.sender, address(hook), borrowAmount)) {
            revert InsufficientAmount(borrowAmount);
        }
        uint256 liquidateValue = 0;
        if (borrowToken == CurrencyLibrary.ADDRESS_ZERO) {
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
        hook.release{value: liquidateValue}(params);
        profit = _position.marginAmount + _position.marginTotal;
        marginToken.transfer(address(this), msg.sender, profit);
        if (msg.value > liquidateValue) {
            transferNative(msg.sender, msg.value - liquidateValue);
        }
        emit Liquidate(
            _position.poolId, msg.sender, positionId, _position.marginAmount, _position.marginTotal, borrowAmount
        );
        _burnPosition(positionId, BurnType.LIQUIDATE);
    }

    function getMaxDecrease(uint256 positionId) external view returns (uint256 maxAmount) {
        MarginPosition memory _position = getPosition(positionId);
        maxAmount = checker.getMaxDecrease(_position, address(hook));
    }

    function modify(uint256 positionId, int256 changeAmount) external payable {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        MarginPosition storage _position = _positions[positionId];
        if (_position.rateCumulativeLast > 0) {
            uint256 rateLast =
                hook.marginFees().getBorrowRateCumulativeLast(address(hook), _position.poolId, _position.marginForOne);
            _position.borrowAmount = uint112(uint256(_position.borrowAmount) * rateLast / _position.rateCumulativeLast);
        }
        HookStatus memory _status = hook.getStatus(_position.poolId);
        Currency marginToken = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        uint256 amount = changeAmount < 0 ? uint256(-changeAmount) : uint256(changeAmount);
        if (changeAmount > 0) {
            bool b = marginToken.transfer(msg.sender, address(this), amount);
            _position.marginAmount += uint128(amount);
            require(b, "TRANSFER_ERR");
        } else {
            require(amount <= checker.getMaxDecrease(_position, address(hook)), "OVER_AMOUNT");
            bool b = marginToken.transfer(address(this), msg.sender, amount);
            _position.marginAmount -= uint128(amount);
            require(b, "TRANSFER_ERR");
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
}
