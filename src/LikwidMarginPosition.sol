// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

// Local
import {BasePositionManager} from "./base/BasePositionManager.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {IProtocolFees} from "./interfaces/IProtocolFees.sol";
import {IMarginBase} from "./interfaces/IMarginBase.sol";
import {IVault} from "./interfaces/IVault.sol";
import {CurrencyPoolLibrary} from "./libraries/CurrencyPoolLibrary.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {InterestMath} from "./libraries/InterestMath.sol";
import {MarginPosition} from "./libraries/MarginPosition.sol";
import {Math} from "./libraries/Math.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {PositionLibrary} from "./libraries/PositionLibrary.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {StateLibrary} from "./libraries/StateLibrary.sol";
import {TimeLibrary} from "./libraries/TimeLibrary.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {SwapMath} from "./libraries/SwapMath.sol";
import {FixedPoint96} from "./libraries/FixedPoint96.sol";
import {MarginActions} from "./types/MarginActions.sol";
import {BalanceDelta} from "./types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "./types/Currency.sol";
import {MarginLevels, MarginLevelsLibrary} from "./types/MarginLevels.sol";
import {MarginState} from "./types/MarginState.sol";
import {PoolId} from "./types/PoolId.sol";
import {PoolKey} from "./types/PoolKey.sol";
import {Reserves} from "./types/Reserves.sol";
import {PoolState} from "./types/PoolState.sol";
import {MarginBalanceDelta} from "./types/MarginBalanceDelta.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "./types/BalanceDelta.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";

contract LikwidMarginPosition is IMarginPositionManager, BasePositionManager {
    using SafeCast for *;
    using CurrencyLibrary for Currency;
    using CurrencyPoolLibrary for Currency;
    using PerLibrary for uint256;
    using FeeLibrary for uint24;
    using CustomRevert for bytes4;
    using PositionLibrary for address;
    using MarginLevelsLibrary for MarginLevels;
    using TimeLibrary for uint32;
    using MarginPosition for MarginPosition.State;
    using MarginPosition for mapping(bytes32 => MarginPosition.State);

    error PairNotExists();
    error PositionLiquidated();
    error MirrorTooMuch();
    error ReservesNotEnough();
    error BorrowTooMuch();
    error LeverageOverflow();

    error MarginTransferFailed(uint256 amount);
    error InvalidLevel();

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
        REPAY,
        CLOSE,
        LIQUIDATE_BURN,
        LIQUIDATE_CALL
    }

    uint8 constant MAX_LEVERAGE = 5; // 5x

    mapping(uint256 tokenId => MarginPosition.State positionInfo) public positionInfos;
    MarginLevels public marginLevels;

    constructor(address initialOwner, IVault _vault)
        BasePositionManager("LIKWIDMarginPositionManager", "LMPM", initialOwner, _vault)
    {
        MarginLevels _marginLevels;
        _marginLevels = _marginLevels.setMinMarginLevel(1170000);
        _marginLevels = _marginLevels.setMinBorrowLevel(1400000);
        _marginLevels = _marginLevels.setLiquidateLevel(1100000);
        _marginLevels = _marginLevels.setLiquidationRatio(950000);
        _marginLevels = _marginLevels.setCallerProfit(10000);
        _marginLevels = _marginLevels.setProtocolProfit(5000);
        marginLevels = _marginLevels;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (MarginActions action, bytes memory params) = abi.decode(data, (MarginActions, bytes));

        if (action == MarginActions.LIQUIDATE_BURN) {
            return handleLiquidateBurn(params);
        } else {
            return handleMargin(params);
        }
    }

    function _getPoolState(PoolId poolId) internal view returns (PoolState memory state) {
        state = StateLibrary.getCurrentState(vault, poolId);
    }

    function _getUpdatedCumulativeValues(PoolId poolId)
        private
        view
        returns (
            uint256 borrow0CumulativeLast,
            uint256 borrow1CumulativeLast,
            uint256 deposit0CumulativeLast,
            uint256 deposit1CumulativeLast
        )
    {
        PoolState memory state = _getPoolState(poolId);
        return (
            state.borrow0CumulativeLast,
            state.borrow1CumulativeLast,
            state.deposit0CumulativeLast,
            state.deposit1CumulativeLast
        );
    }

    function getPositionState(uint256 tokenId) external view returns (MarginPosition.State memory position) {
        PoolId poolId = poolIds[tokenId];
        position = positionInfos[tokenId];
        (
            uint256 borrow0CumulativeLast,
            uint256 borrow1CumulativeLast,
            uint256 deposit0CumulativeLast,
            uint256 deposit1CumulativeLast
        ) = _getUpdatedCumulativeValues(poolId);
        uint256 depositCumulativeLast = position.marginForOne ? deposit1CumulativeLast : deposit0CumulativeLast;
        uint256 borrowCumulativeLast = position.marginForOne ? borrow0CumulativeLast : borrow1CumulativeLast;
        position.marginAmount =
            Math.mulDiv(position.marginAmount, depositCumulativeLast, position.depositCumulativeLast).toUint128();
        position.marginTotal =
            Math.mulDiv(position.marginTotal, depositCumulativeLast, position.depositCumulativeLast).toUint128();
        position.debtAmount =
            Math.mulDiv(position.debtAmount, borrowCumulativeLast, position.borrowCumulativeLast).toUint128();

        position.depositCumulativeLast = depositCumulativeLast;
        position.borrowCumulativeLast = borrowCumulativeLast;
    }

    function checkLiquidate(uint256 tokenId)
        external
        view
        returns (bool liquidated, uint256 assetsAmount, uint256 debtAmount)
    {
        PoolId poolId = poolIds[tokenId];
        MarginPosition.State memory info = positionInfos[tokenId];
        (liquidated, assetsAmount, debtAmount) = _checkLiquidate(poolId, tokenId, info);
    }

    function _checkLiquidate(PoolId poolId, uint256 tokenId, MarginPosition.State memory info)
        internal
        view
        returns (bool liquidated, uint256 assetsAmount, uint256 debtAmount)
    {
        PoolState memory state = _getPoolState(poolId);

        uint256 depositCumulativeLast = info.marginForOne ? state.deposit1CumulativeLast : state.deposit0CumulativeLast;
        uint256 borrowCumulativeLast = info.marginForOne ? state.borrow0CumulativeLast : state.borrow1CumulativeLast;
        MarginPosition.State memory position = positionInfos[tokenId];

        uint256 level =
            MarginPosition.marginLevel(position, state.truncatedReserves, borrowCumulativeLast, depositCumulativeLast);

        MarginLevels _marginLevels = marginLevels;
        liquidated = level < _marginLevels.liquidateLevel();
        if (liquidated) {
            position.marginAmount =
                Math.mulDiv(position.marginAmount, depositCumulativeLast, position.depositCumulativeLast).toUint128();
            position.marginTotal =
                Math.mulDiv(position.marginTotal, depositCumulativeLast, position.depositCumulativeLast).toUint128();
            assetsAmount = position.marginAmount + position.marginTotal;
            debtAmount = Math.mulDiv(position.debtAmount, borrowCumulativeLast, position.borrowCumulativeLast);
        }
    }

    function _checkMinLevel(
        Reserves pairReserves,
        uint256 borrowCumulativeLast,
        uint256 depositCumulativeLast,
        MarginPosition.State memory position
    ) internal view {
        uint256 level = position.marginLevel(pairReserves, borrowCumulativeLast, depositCumulativeLast);
        uint256 minLevel = marginLevels.minBorrowLevel();
        if (position.marginTotal > 0) minLevel = marginLevels.minMarginLevel();
        if (level < minLevel) {
            InvalidLevel.selector.revertWith();
        }
    }

    /// @inheritdoc IMarginPositionManager
    function addMargin(PoolKey memory key, IMarginPositionManager.CreateParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint256 borrowAmount)
    {
        tokenId = _mintPosition(key, params.recipient);
        positionInfos[tokenId].marginForOne = params.marginForOne;
        borrowAmount = margin(
            IMarginPositionManager.MarginParams({
                tokenId: tokenId,
                leverage: params.leverage,
                marginAmount: params.marginAmount,
                borrowAmount: params.borrowAmount,
                borrowAmountMax: params.borrowAmountMax,
                deadline: params.deadline
            })
        );
    }

    /// @inheritdoc IMarginPositionManager
    function margin(IMarginPositionManager.MarginParams memory params)
        public
        payable
        nonReentrant
        ensure(params.deadline)
        returns (uint256 borrowAmount)
    {
        _requireAuth(msg.sender, params.tokenId);
        PoolId poolId = poolIds[params.tokenId];
        PoolKey memory key = poolKeys[poolId];
        PoolState memory poolState = _getPoolState(poolId);
        MarginPosition.State storage position = positionInfos[params.tokenId];
        uint256 borrowRealReserves = poolState.realReserves.reserve01(!position.marginForOne);
        uint256 marginWithoutFee;
        MarginBalanceDelta memory delta;

        if (params.leverage > 0) {
            // --- Margin ---
            uint256 borrowMirrorReserves = poolState.mirrorReserves.reserve01(!position.marginForOne);
            if (Math.mulDiv(borrowMirrorReserves, 100, borrowRealReserves + borrowMirrorReserves) > 90) {
                MirrorTooMuch.selector.revertWith();
            }

            uint256 marginReserves = poolState.realReserves.reserve01(position.marginForOne);
            uint256 marginTotal = params.marginAmount * params.leverage;
            if (marginTotal > marginReserves) ReservesNotEnough.selector.revertWith();
            delta.marginTotal = marginTotal.toUint128();
            (marginWithoutFee,) = poolState.marginFee.deduct(marginTotal);
            (borrowAmount,,) = SwapMath.getAmountIn(
                poolState.pairReserves, poolState.truncatedReserves, poolState.lpFee, position.marginForOne, marginTotal
            );
            params.borrowAmount = borrowAmount.toUint128();
        } else {
            // --- Borrow ---
            uint256 borrowMAXAmount =
                SwapMath.getAmountOut(poolState.pairReserves, !position.marginForOne, params.marginAmount);
            borrowMAXAmount = Math.min(borrowMAXAmount, borrowRealReserves * 20 / 100);
            if (params.borrowAmount > borrowMAXAmount) BorrowTooMuch.selector.revertWith();
            if (params.borrowAmount == 0) params.borrowAmount = borrowMAXAmount.toUint128();
            borrowAmount = params.borrowAmount;
        }
        uint256 borrowCumulativeLast;
        uint256 depositCumulativeLast;
        if (position.marginForOne) {
            borrowCumulativeLast = poolState.borrow0CumulativeLast;
            depositCumulativeLast = poolState.deposit1CumulativeLast;
        } else {
            borrowCumulativeLast = poolState.borrow1CumulativeLast;
            depositCumulativeLast = poolState.deposit0CumulativeLast;
        }

        position.update(
            borrowCumulativeLast,
            depositCumulativeLast,
            params.marginAmount.toInt128(),
            marginWithoutFee,
            params.borrowAmount,
            0
        );
        _checkMinLevel(poolState.pairReserves, borrowCumulativeLast, depositCumulativeLast, position);
        delta.action = MarginActions.MARGIN;
        delta.marginForOne = position.marginForOne;

        int128 amount0Delta;
        int128 amount1Delta;
        int128 amount = -params.marginAmount.toInt128();
        int128 lendAmount = amount - marginWithoutFee.toInt128();
        if (marginWithoutFee == 0) {
            // borrow
            if (position.marginForOne) {
                // margin token1, borrow token0
                amount1Delta = amount;
                amount0Delta = borrowAmount.toInt128();
                // pairDelta = 0
                delta.lendDelta = toBalanceDelta(0, lendAmount);
                delta.mirrorDelta = toBalanceDelta(-borrowAmount.toInt128(), 0);
            } else {
                // margin token0, borrow token1
                amount0Delta = amount;
                amount1Delta = borrowAmount.toInt128();
                // pairDelta = 0
                delta.lendDelta = toBalanceDelta(lendAmount, 0);
                delta.mirrorDelta = toBalanceDelta(0, -borrowAmount.toInt128());
            }
        } else {
            if (position.marginForOne) {
                amount1Delta = amount;
                delta.pairDelta = toBalanceDelta(-borrowAmount.toInt128(), marginWithoutFee.toInt128());
                delta.lendDelta = toBalanceDelta(0, lendAmount);
                delta.mirrorDelta = toBalanceDelta(-borrowAmount.toInt128(), 0);
            } else {
                amount0Delta = amount;
                delta.pairDelta = toBalanceDelta(marginWithoutFee.toInt128(), -borrowAmount.toInt128());
                delta.lendDelta = toBalanceDelta(lendAmount, 0);
                delta.mirrorDelta = toBalanceDelta(0, -borrowAmount.toInt128());
            }
        }
        delta.marginDelta = toBalanceDelta(amount0Delta, amount1Delta);

        bytes memory callbackData = abi.encode(msg.sender, key, delta);
        bytes memory data = abi.encode(MarginActions.MARGIN, callbackData);

        vault.unlock(data);
    }

    /// @inheritdoc IMarginPositionManager
    function repay(uint256 tokenId, uint256 repayAmount, uint256 deadline)
        external
        payable
        nonReentrant
        ensure(deadline)
    {
        _requireAuth(msg.sender, tokenId);
        // PositionInfo storage info = positionInfos[tokenId];
        // PoolId poolId = poolIds[tokenId];
        // PoolKey memory key = poolKeys[poolId];
        // uint24 minLevel = _isBorrow(info) ? marginLevels.minBorrowLevel() : marginLevels.minMarginLevel();
        // bytes32 salt = bytes32(tokenId);
        // MarginPosition.State memory position =
        //     StateLibrary.getMarginPositionState(vault, poolId, address(this), _isBorrow(info), salt);

        // IVault.MarginParams memory marginParams = IVault.MarginParams({
        //     marginForOne: _isMarginForOne(info),
        //     amount: repayAmount.toInt128(),
        //     marginTotal: position.marginTotal,
        //     borrowAmount: 0,
        //     changeAmount: 0,
        //     minMarginLevel: minLevel,
        //     salt: bytes32(tokenId)
        // });

        // bytes memory callbackData = abi.encode(msg.sender, key, marginParams);
        // bytes memory data = abi.encode(Actions.REPAY, callbackData);

        // vault.unlock(data);
    }

    /// @inheritdoc IMarginPositionManager
    function close(uint256 tokenId, uint24 closeMillionth, uint256 profitAmountMin, uint256 deadline)
        external
        nonReentrant
        ensure(deadline)
    {
        _requireAuth(msg.sender, tokenId);
        // PositionInfo storage info = positionInfos[tokenId];
        // PoolId poolId = poolIds[tokenId];
        // PoolKey memory key = poolKeys[poolId];
        // bytes32 salt = bytes32(tokenId);
        // bytes32 positionKey = address(this).calculatePositionKey(_isBorrow(info), salt);
        // IVault.CloseParams memory marginParams = IVault.CloseParams({
        //     positionKey: positionKey,
        //     rewardAmount: 0,
        //     closeMillionth: closeMillionth,
        //     salt: bytes32(tokenId)
        // });

        // bytes memory callbackData = abi.encode(msg.sender, key, marginParams);
        // bytes memory data = abi.encode(Actions.CLOSE, callbackData);

        // bytes memory result = vault.unlock(data);
        // (uint256 profitAmount) = abi.decode(result, (uint256));
        // if (profitAmount < profitAmountMin) {
        //     InsufficientCloseReceived.selector.revertWith();
        // }

        // if (closeMillionth == 1_000_000) {
        //     _burn(tokenId);
        // }
    }

    /// @inheritdoc IMarginPositionManager
    function liquidateBurn(uint256 tokenId) external nonReentrant returns (uint256 profit) {
        // PositionInfo storage info = positionInfos[tokenId];
        // PoolId poolId = poolIds[tokenId];
        // (bool liquidated, uint256 assetsAmount,) = _checkLiquidate(tokenId, poolId, info);
        // if (!liquidated) {
        //     PositionNotLiquidated.selector.revertWith();
        // }
        // uint256 callerProfitAmount = assetsAmount.mulDivMillion(marginLevels.callerProfit());
        // uint256 protocolProfitAmount = assetsAmount.mulDivMillion(marginLevels.protocolProfit());
        // PoolKey memory key = poolKeys[poolId];
        // bytes32 salt = bytes32(tokenId);
        // bytes32 positionKey = address(this).calculatePositionKey(_isBorrow(info), salt);
        // IVault.CloseParams memory marginParams = IVault.CloseParams({
        //     positionKey: positionKey,
        //     rewardAmount: callerProfitAmount + protocolProfitAmount,
        //     closeMillionth: uint24(PerLibrary.ONE_MILLION),
        //     salt: bytes32(tokenId)
        // });

        // bytes memory callbackData =
        //     abi.encode(msg.sender, key, marginParams, _isMarginForOne(info), callerProfitAmount, protocolProfitAmount);
        // bytes memory data = abi.encode(Actions.LIQUIDATE_BURN, callbackData);

        // bytes memory result = vault.unlock(data);
        // profit = abi.decode(result, (uint256));
    }

    /// @inheritdoc IMarginPositionManager
    function liquidateCall(uint256 tokenId)
        external
        payable
        nonReentrant
        returns (uint256 profit, uint256 repayAmount)
    {
        // PositionInfo storage info = positionInfos[tokenId];
        // PoolId poolId = poolIds[tokenId];
        // (bool liquidated, uint256 assetsAmount, uint256 debtAmount) = _checkLiquidate(tokenId, poolId, info);
        // if (!liquidated) {
        //     PositionNotLiquidated.selector.revertWith();
        // }
        // Reserves pairReserves = StateLibrary.getPairReserves(vault, poolId);
        // (uint128 reserve0, uint128 reserve1) = pairReserves.reserves();
        // (uint256 reserveBorrow, uint256 reserveMargin) =
        //     _isMarginForOne(info) ? (reserve0, reserve1) : (reserve1, reserve0);
        // uint24 _liquidationRatio = marginLevels.liquidationRatio();
        // repayAmount = Math.mulDiv(reserveBorrow, assetsAmount, reserveMargin);
        // repayAmount = repayAmount.mulDivMillion(_liquidationRatio);
        // profit = assetsAmount;
        // PoolKey memory key = poolKeys[poolId];
        // IVault.MarginParams memory marginParams = IVault.MarginParams({
        //     marginForOne: _isMarginForOne(info),
        //     amount: repayAmount.toInt128(),
        //     marginTotal: 0,
        //     borrowAmount: 0,
        //     changeAmount: debtAmount.toInt128(),
        //     minMarginLevel: 1, // no zero level
        //     salt: bytes32(tokenId)
        // });

        // bytes memory callbackData = abi.encode(msg.sender, key, marginParams);
        // bytes memory data = abi.encode(Actions.LIQUIDATE_CALL, callbackData);

        // vault.unlock(data);
    }

    /// @inheritdoc IMarginPositionManager
    function modify(uint256 tokenId, int128 changeAmount) external payable nonReentrant {
        _requireAuth(msg.sender, tokenId);
        // PositionInfo storage info = positionInfos[tokenId];
        // PoolId poolId = poolIds[tokenId];
        // PoolKey memory key = poolKeys[poolId];
        // uint24 minLevel = _isBorrow(info) ? marginLevels.minBorrowLevel() : marginLevels.minMarginLevel();

        // IVault.MarginParams memory marginParams = IVault.MarginParams({
        //     marginForOne: _isMarginForOne(info),
        //     amount: 0,
        //     marginTotal: 0,
        //     borrowAmount: 0,
        //     changeAmount: changeAmount,
        //     minMarginLevel: minLevel,
        //     salt: bytes32(tokenId)
        // });

        // bytes memory callbackData = abi.encode(msg.sender, key, marginParams);
        // bytes memory data = abi.encode(Actions.MODIFY, callbackData);

        // vault.unlock(data);
    }

    function handleMargin(bytes memory _data) internal returns (bytes memory) {
        (address sender, PoolKey memory key, MarginBalanceDelta memory params) =
            abi.decode(_data, (address, PoolKey, MarginBalanceDelta));

        (BalanceDelta delta, uint256 feeAmount) = vault.marginBalance(key, params);

        _processDelta(sender, key, delta, 0, 0, 0, 0);

        return abi.encode(feeAmount);
    }

    function handleLiquidateBurn(bytes memory _data) internal returns (bytes memory) {
        // (
        //     address sender,
        //     PoolKey memory key,
        //     MarginParams memory params,
        //     bool marginForOne,
        //     uint256 callerProfitAmount,
        //     uint256 protocolProfitAmount
        // ) = abi.decode(_data, (address, PoolKey, MarginParams, bool, uint256, uint256));

        // (, uint256 profitAmount) = vault.margin(key, params);
        // if (profitAmount < callerProfitAmount) {
        //     callerProfitAmount = profitAmount;
        //     protocolProfitAmount = 0;
        // } else {
        //     protocolProfitAmount = profitAmount - callerProfitAmount;
        // }
        // Currency marginCurrency = marginForOne ? key.currency1 : key.currency0;
        // if (protocolProfitAmount > 0) {
        //     address feeTo = IProtocolFees(address(vault)).protocolFeeController();
        //     if (feeTo == address(0)) {
        //         feeTo = owner;
        //     }
        //     marginCurrency.take(vault, feeTo, protocolProfitAmount, false);
        // }
        // if (callerProfitAmount > 0) {
        //     marginCurrency.take(vault, sender, callerProfitAmount, false);
        // }

        return abi.encode(0);
    }

    // ******************** OWNER CALL ********************
    function setMinMarginLevel(uint24 _minMarginLevel) external onlyOwner {
        if (_minMarginLevel < marginLevels.liquidateLevel()) {
            InvalidLevel.selector.revertWith();
        }
        uint24 old = marginLevels.minMarginLevel();
        marginLevels = marginLevels.setMinMarginLevel(_minMarginLevel);
        emit MinMarginLevelChanged(old, _minMarginLevel);
    }

    function setMinBorrowLevel(uint24 _minBorrowLevel) external onlyOwner {
        if (_minBorrowLevel < marginLevels.liquidateLevel()) {
            InvalidLevel.selector.revertWith();
        }
        uint24 old = marginLevels.minBorrowLevel();
        marginLevels = marginLevels.setMinBorrowLevel(_minBorrowLevel);
        emit MinBorrowLevelChanged(old, _minBorrowLevel);
    }

    function setLiquidateLevel(uint24 _liquidateLevel) external onlyOwner {
        if (marginLevels.minMarginLevel() < _liquidateLevel || marginLevels.minBorrowLevel() < _liquidateLevel) {
            InvalidLevel.selector.revertWith();
        }
        uint24 old = marginLevels.liquidateLevel();
        marginLevels = marginLevels.setLiquidateLevel(_liquidateLevel);
        emit LiquidateLevelChanged(old, _liquidateLevel);
    }

    function setLiquidationRatio(uint24 _liquidationRatio) external onlyOwner {
        uint24 old = marginLevels.liquidationRatio();
        marginLevels = marginLevels.setLiquidationRatio(_liquidationRatio);
        emit LiquidationRatioChanged(old, _liquidationRatio);
    }

    function setCallerProfit(uint24 _callerProfit) external onlyOwner {
        uint24 old = marginLevels.callerProfit();
        marginLevels = marginLevels.setCallerProfit(_callerProfit);
        emit CallerProfitChanged(old, _callerProfit);
    }

    function setProtocolProfit(uint24 _protocolProfit) external onlyOwner {
        uint24 old = marginLevels.protocolProfit();
        marginLevels = marginLevels.setProtocolProfit(_protocolProfit);
        emit ProtocolProfitChanged(old, _protocolProfit);
    }
}
