// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {SafeCallback} from "../base/SafeCallback.sol";
import {IMarginCore} from "../interfaces/IMarginCore.sol";
import {IMarginPositionReceiver} from "../interfaces/IMarginPositionReceiver.sol";
import {IVault} from "../interfaces/IVault.sol";
import {CurrencyPoolLibrary} from "../libraries/CurrencyPoolLibrary.sol";
import {CustomRevert} from "../libraries/CustomRevert.sol";
import {FeeLibrary} from "../libraries/FeeLibrary.sol";
import {MarginPosition} from "../libraries/MarginPosition.sol";
import {Math} from "../libraries/Math.sol";
import {PerLibrary} from "../libraries/PerLibrary.sol";
import {PositionLibrary} from "../libraries/PositionLibrary.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {StateLibrary} from "../libraries/StateLibrary.sol";
import {CurrentStateLibrary} from "../libraries/CurrentStateLibrary.sol";
import {SwapMath} from "../libraries/SwapMath.sol";
import {MarginActions} from "../types/MarginActions.sol";
import {BalanceDelta, toBalanceDelta} from "../types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "../types/Currency.sol";
import {MarginLevels, MarginLevelsLibrary} from "../types/MarginLevels.sol";
import {PoolId} from "../types/PoolId.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {Reserves} from "../types/Reserves.sol";
import {PoolState} from "../types/PoolState.sol";
import {MarginBalanceDelta} from "../types/MarginBalanceDelta.sol";

/// @title Likwid margin core
/// @notice Owns the margin position ledger and enforces its safety invariants. Sits between the
/// vault (as its sole margin controller) and untrusted periphery contracts: any caller may manage
/// positions scoped to its own address, and anyone may liquidate any unhealthy position.
contract LikwidMarginCore is IMarginCore, SafeCallback, Owned {
    using SafeCast for *;
    using CurrencyLibrary for Currency;
    using CurrencyPoolLibrary for Currency;
    using PerLibrary for uint256;
    using FeeLibrary for uint24;
    using CustomRevert for bytes4;
    using MarginLevelsLibrary for MarginLevels;
    using MarginPosition for MarginPosition.State;

    uint8 constant MAX_LEVERAGE = 5; // 5x
    uint8 constant MAX_MIRROR_RATIO = 80; // 80%
    uint24 constant MARGIN_MINIMUM_RATIO = 10000000; // 1/1000_0000

    mapping(PoolId poolId => mapping(bytes32 positionKey => MarginPosition.State)) private positions;
    MarginLevels public marginLevels;

    constructor(address initialOwner, IVault _vault) SafeCallback(_vault) Owned(initialOwner) {
        MarginLevels _marginLevels;
        _marginLevels = _marginLevels.setMinMarginLevel(1170000);
        _marginLevels = _marginLevels.setMinBorrowLevel(1400000);
        _marginLevels = _marginLevels.setLiquidateLevel(1100000);
        _marginLevels = _marginLevels.setLiquidationRatio(950000);
        _marginLevels = _marginLevels.setCallerProfit(10000);
        marginLevels = _marginLevels;
    }

    /// @inheritdoc IMarginCore
    function getPositionState(PoolId poolId, address owner, bytes32 salt)
        external
        view
        returns (MarginPosition.State memory position)
    {
        position = positions[poolId][PositionLibrary.calculatePositionKey(owner, salt)];
        if (position.borrowCumulativeLast == 0 || position.depositCumulativeLast == 0) {
            // empty or never-touched position: nothing to accrue
            return position;
        }
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        (uint256 borrowCumulativeLast, uint256 depositCumulativeLast) =
            _getPoolCumulativeValues(state, position.marginForOne);

        (uint256 marginAmount, uint256 marginTotal, uint256 debtAmount) =
            position.accrue(borrowCumulativeLast, depositCumulativeLast);
        position.marginAmount = marginAmount.toUint128();
        position.marginTotal = marginTotal.toUint128();
        position.debtAmount = debtAmount.toUint128();

        position.depositCumulativeLast = depositCumulativeLast;
        position.borrowCumulativeLast = borrowCumulativeLast;
    }

    /// @inheritdoc IMarginCore
    function margin(PoolKey calldata key, IMarginCore.MarginParams calldata params)
        external
        returns (uint256 borrowAmount, uint256 swapFeeAmount, BalanceDelta delta)
    {
        if (params.leverage > MAX_LEVERAGE) {
            ExceedMaxLeverage.selector.revertWith();
        }
        PoolId poolId = key.toId();
        PoolState memory poolState = CurrentStateLibrary.getState(vault, poolId);
        if (poolState.lpFee < 3000) revert LowFeePoolMarginBanned();

        MarginPosition.State storage position = positions[poolId][_positionKey(msg.sender, params.salt)];
        if (position.marginAmount == 0 && position.marginTotal == 0 && position.debtAmount == 0) {
            position.marginForOne = params.marginForOne;
        } else if (position.marginForOne != params.marginForOne) {
            // adding to an existing position must not silently flip its direction
            DirectionMismatch.selector.revertWith();
        }

        MarginBalanceDelta memory balanceDelta;
        balanceDelta.action = MarginActions.MARGIN;
        balanceDelta.marginForOne = position.marginForOne;
        uint256 marginReserve = poolState.pairReserves.reserve01(position.marginForOne);
        if (params.marginAmount < marginReserve / MARGIN_MINIMUM_RATIO) {
            MarginBelowMinimum.selector.revertWith();
        }
        uint256 minLevel;
        if (params.leverage > 0) {
            minLevel = marginLevels.minMarginLevel();
            (borrowAmount, balanceDelta.marginFeeAmount, swapFeeAmount) =
                _executeAddLeverage(params, poolState, position, balanceDelta);
        } else {
            minLevel = marginLevels.minBorrowLevel();
            borrowAmount = _executeAddCollateralAndBorrow(params, poolState, position, balanceDelta, minLevel);
        }
        if (params.borrowAmountMax > 0 && borrowAmount > params.borrowAmountMax) {
            ExceedBorrowAmountMax.selector.revertWith();
        }
        balanceDelta.swapFeeAmount = swapFeeAmount;

        delta = vault.marginBalance(key, balanceDelta);
        _takePositives(key, delta, params.recipient);
        _checkMinLevelAfterOp(poolId, position, minLevel);

        emit Margin(
            poolId,
            msg.sender,
            params.salt,
            position.marginAmount,
            position.marginTotal,
            position.debtAmount,
            position.marginForOne
        );
    }

    function _executeAddLeverage(
        IMarginCore.MarginParams memory params,
        PoolState memory poolState,
        MarginPosition.State storage position,
        MarginBalanceDelta memory delta
    ) internal returns (uint256 borrowAmount, uint256 marginFeeAmount, uint256 swapFeeAmount) {
        uint256 marginReserves = poolState.realReserves.reserve01(position.marginForOne);
        uint256 marginTotal = params.marginAmount * params.leverage;
        if (marginTotal > marginReserves) ReservesNotEnough.selector.revertWith();

        delta.marginTotal = marginTotal.toUint128();
        uint256 marginWithoutFee;
        (marginWithoutFee, marginFeeAmount) = poolState.marginFee.deduct(marginTotal);
        (borrowAmount,, swapFeeAmount) = SwapMath.getAmountIn(
            poolState.pairReserves, poolState.truncatedReserves, poolState.lpFee, position.marginForOne, marginTotal
        );

        (uint256 borrowCumulativeLast, uint256 depositCumulativeLast) =
            _getPoolCumulativeValues(poolState, position.marginForOne);

        uint256 borrowMirrorReserves = poolState.mirrorReserves.reserve01(!position.marginForOne) + borrowAmount;
        uint256 borrowRealReserves = poolState.realReserves.reserve01(!position.marginForOne);
        if (Math.mulDiv(borrowMirrorReserves, 100, borrowRealReserves + borrowMirrorReserves) > MAX_MIRROR_RATIO) {
            MirrorTooMuch.selector.revertWith();
        }

        position.update(
            borrowCumulativeLast,
            depositCumulativeLast,
            params.marginAmount.toInt128(),
            marginWithoutFee,
            borrowAmount,
            0
        );

        int128 amount = -params.marginAmount.toInt128();
        int128 lendAmount = amount - marginWithoutFee.toInt128();

        delta.marginDelta = _toPoolDelta(position.marginForOne, 0, amount);
        delta.pairDelta = _toPoolDelta(position.marginForOne, -borrowAmount.toInt128(), marginWithoutFee.toInt128());
        delta.lendDelta = _toPoolDelta(position.marginForOne, 0, lendAmount);
        delta.mirrorDelta = _toPoolDelta(position.marginForOne, -borrowAmount.toInt128(), 0);
    }

    function _executeAddCollateralAndBorrow(
        IMarginCore.MarginParams memory params,
        PoolState memory poolState,
        MarginPosition.State storage position,
        MarginBalanceDelta memory delta,
        uint256 minBorrowLevel
    ) internal returns (uint256 borrowAmount) {
        (uint256 borrowMaxAmount,) = SwapMath.getAmountOut(
            poolState.pairReserves, poolState.lpFee, !position.marginForOne, params.marginAmount
        );
        if (minBorrowLevel > PerLibrary.ONE_MILLION) {
            borrowMaxAmount = Math.mulDiv(borrowMaxAmount, PerLibrary.ONE_MILLION, minBorrowLevel);
        }
        uint256 borrowRealReserves = poolState.realReserves.reserve01(!position.marginForOne);
        borrowMaxAmount = Math.min(borrowMaxAmount, borrowRealReserves * 20 / 100);
        borrowAmount = params.borrowAmount == type(uint256).max ? borrowMaxAmount : params.borrowAmount;
        if (borrowAmount > borrowMaxAmount) BorrowTooMuch.selector.revertWith();
        (uint256 borrowCumulativeLast, uint256 depositCumulativeLast) =
            _getPoolCumulativeValues(poolState, position.marginForOne);

        uint256 borrowMirrorReserves = poolState.mirrorReserves.reserve01(!position.marginForOne) + borrowAmount;
        borrowRealReserves -= borrowAmount;
        if (Math.mulDiv(borrowMirrorReserves, 100, borrowRealReserves + borrowMirrorReserves) > MAX_MIRROR_RATIO) {
            MirrorTooMuch.selector.revertWith();
        }

        position.update(
            borrowCumulativeLast, depositCumulativeLast, params.marginAmount.toInt128(), 0, borrowAmount, 0
        );

        int128 amount = -params.marginAmount.toInt128();

        delta.lendDelta = _toPoolDelta(position.marginForOne, 0, amount);
        delta.mirrorDelta = _toPoolDelta(position.marginForOne, -borrowAmount.toInt128(), 0);
        delta.marginDelta = _toPoolDelta(position.marginForOne, borrowAmount.toInt128(), amount);
    }

    /// @inheritdoc IMarginCore
    function repay(PoolKey calldata key, bytes32 salt, uint256 repayAmount, address recipient)
        external
        returns (uint256 releaseAmount, uint256 realRepayAmount, BalanceDelta delta)
    {
        PoolId poolId = key.toId();
        PoolState memory poolState = CurrentStateLibrary.getState(vault, poolId);
        MarginPosition.State storage position = positions[poolId][_positionKey(msg.sender, salt)];

        (uint256 borrowCumulativeLast, uint256 depositCumulativeLast) =
            _getPoolCumulativeValues(poolState, position.marginForOne);

        (releaseAmount, realRepayAmount) =
            position.update(borrowCumulativeLast, depositCumulativeLast, 0, 0, 0, repayAmount);

        MarginBalanceDelta memory balanceDelta;
        balanceDelta.lendDelta = _toPoolDelta(position.marginForOne, 0, releaseAmount.toInt128());
        balanceDelta.mirrorDelta = _toPoolDelta(position.marginForOne, realRepayAmount.toInt128(), 0);
        balanceDelta.action = MarginActions.REPAY;
        balanceDelta.marginForOne = position.marginForOne;
        balanceDelta.marginDelta =
            _toPoolDelta(position.marginForOne, -realRepayAmount.toInt128(), releaseAmount.toInt128());

        delta = vault.marginBalance(key, balanceDelta);
        _takePositives(key, delta, recipient);
        _checkMinLevelAfterOp(poolId, position, marginLevels.liquidateLevel());

        emit Repay(
            poolId,
            msg.sender,
            salt,
            position.marginAmount,
            position.marginTotal,
            position.debtAmount,
            releaseAmount,
            realRepayAmount
        );
    }

    /// @inheritdoc IMarginCore
    function close(PoolKey calldata key, bytes32 salt, uint24 closeMillionth, uint256 closeAmountMin, address recipient)
        external
        returns (uint256 closeAmount, BalanceDelta delta)
    {
        PoolId poolId = key.toId();
        PoolState memory poolState = CurrentStateLibrary.getState(vault, poolId);
        MarginPosition.State storage position = positions[poolId][_positionKey(msg.sender, salt)];
        (uint256 borrowCumulativeLast, uint256 depositCumulativeLast) =
            _getPoolCumulativeValues(poolState, position.marginForOne);

        uint24 liquidateLevel = marginLevels.liquidateLevel();
        _checkMinLevel(
            poolState.truncatedReserves, borrowCumulativeLast, depositCumulativeLast, position, liquidateLevel
        );

        uint256 releaseAmount;
        uint256 repayAmount;
        uint256 lostAmount;
        uint256 swapFeeAmount;
        (releaseAmount, repayAmount, closeAmount, lostAmount, swapFeeAmount) = position.close(
            poolState.pairReserves,
            poolState.truncatedReserves,
            poolState.lpFee,
            borrowCumulativeLast,
            depositCumulativeLast,
            0,
            closeMillionth
        );
        if (lostAmount > 0 || (closeAmountMin > 0 && closeAmount < closeAmountMin)) {
            InsufficientCloseReceived.selector.revertWith();
        }

        MarginBalanceDelta memory balanceDelta;
        balanceDelta.lendDelta = _toPoolDelta(position.marginForOne, 0, releaseAmount.toInt128());
        balanceDelta.mirrorDelta = _toPoolDelta(position.marginForOne, repayAmount.toInt128(), 0);
        balanceDelta.pairDelta =
            _toPoolDelta(position.marginForOne, repayAmount.toInt128(), -(releaseAmount - closeAmount).toInt128());
        balanceDelta.action = MarginActions.CLOSE;
        balanceDelta.swapFeeAmount = swapFeeAmount;
        balanceDelta.marginForOne = position.marginForOne;
        balanceDelta.marginDelta = _toPoolDelta(position.marginForOne, 0, closeAmount.toInt128());

        delta = vault.marginBalance(key, balanceDelta);
        _takePositives(key, delta, recipient);
        _checkMinLevelAfterOp(poolId, position, liquidateLevel);

        emit Close(
            poolId,
            msg.sender,
            salt,
            position.marginAmount,
            position.marginTotal,
            position.debtAmount,
            releaseAmount,
            repayAmount,
            closeAmount
        );
    }

    /// @inheritdoc IMarginCore
    function modify(PoolKey calldata key, bytes32 salt, int128 changeAmount, address recipient)
        external
        returns (BalanceDelta delta)
    {
        PoolId poolId = key.toId();
        PoolState memory poolState = CurrentStateLibrary.getState(vault, poolId);
        MarginPosition.State storage position = positions[poolId][_positionKey(msg.sender, salt)];

        (uint256 borrowCumulativeLast, uint256 depositCumulativeLast) =
            _getPoolCumulativeValues(poolState, position.marginForOne);

        position.update(borrowCumulativeLast, depositCumulativeLast, changeAmount, 0, 0, 0);

        MarginBalanceDelta memory balanceDelta;
        int128 amount = -changeAmount.toInt128();
        balanceDelta.lendDelta = _toPoolDelta(position.marginForOne, 0, amount);
        balanceDelta.action = MarginActions.MODIFY;
        balanceDelta.marginForOne = position.marginForOne;
        balanceDelta.marginDelta = _toPoolDelta(position.marginForOne, 0, amount);

        delta = vault.marginBalance(key, balanceDelta);
        _takePositives(key, delta, recipient);

        if (changeAmount < 0) {
            _checkMinLevelAfterOp(poolId, position, marginLevels.minBorrowLevel());
        }

        emit Modify(
            poolId,
            msg.sender,
            salt,
            position.marginAmount,
            position.marginTotal,
            position.debtAmount,
            changeAmount
        );
    }

    /// @inheritdoc IMarginCore
    function transferPosition(PoolKey calldata key, bytes32 salt, address newOwner, bytes32 newSalt) external {
        PoolId poolId = key.toId();
        MarginPosition.State storage from = positions[poolId][_positionKey(msg.sender, salt)];
        MarginPosition.State storage to = positions[poolId][_positionKey(newOwner, newSalt)];
        if (to.marginAmount != 0 || to.marginTotal != 0 || to.debtAmount != 0) {
            PositionOccupied.selector.revertWith();
        }
        if (from.marginAmount == 0 && from.marginTotal == 0 && from.debtAmount == 0) {
            PositionEmpty.selector.revertWith();
        }
        to.marginForOne = from.marginForOne;
        to.marginAmount = from.marginAmount;
        to.marginTotal = from.marginTotal;
        to.depositCumulativeLast = from.depositCumulativeLast;
        to.debtAmount = from.debtAmount;
        to.borrowCumulativeLast = from.borrowCumulativeLast;
        delete positions[poolId][_positionKey(msg.sender, salt)];

        emit TransferPosition(poolId, msg.sender, salt, newOwner, newSalt);

        // Pushing into another account's namespace requires that account to opt in, so an
        // attacker cannot pre-seed a hostile position under a contract's predictable slot
        // (e.g. an NFT wrapper's next tokenId). Self-rekeys and EOA recipients are exempt.
        // A contract that does not implement the hook (call reverts) is treated as rejecting.
        if (newOwner != msg.sender && newOwner.code.length > 0) {
            try IMarginPositionReceiver(newOwner).onMarginPositionReceived(key, newSalt, msg.sender) returns (
                bytes4 retval
            ) {
                if (retval != IMarginPositionReceiver.onMarginPositionReceived.selector) {
                    PositionTransferRejected.selector.revertWith();
                }
            } catch {
                PositionTransferRejected.selector.revertWith();
            }
        }
    }

    /// @inheritdoc IMarginCore
    function liquidateCall(PoolKey calldata key, address owner, bytes32 salt, address recipient, uint256 deadline)
        external
        payable
        returns (uint256 profit, uint256 repayAmount)
    {
        _ensure(deadline);
        PoolId poolId = key.toId();
        PoolState memory poolState = CurrentStateLibrary.getState(vault, poolId);
        MarginPosition.State storage position = positions[poolId][_positionKey(owner, salt)];
        (bool liquidated, uint256 marginAmount, uint256 marginTotal, uint256 debtAmount) =
            _checkLiquidate(poolState, position);
        if (!liquidated) {
            PositionNotLiquidated.selector.revertWith();
        }
        (uint128 reserve0, uint128 reserve1) = poolState.truncatedReserves.reserves();
        (uint256 reserveBorrow, uint256 reserveMargin) =
            position.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        profit = marginAmount + marginTotal;
        repayAmount = Math.mulDivRoundingUp(reserveBorrow, profit, reserveMargin);
        uint256 needPayAmount = repayAmount.mulDivMillion(marginLevels.liquidationRatio());

        (uint256 borrowCumulativeLast, uint256 depositCumulativeLast) =
            _getPoolCumulativeValues(poolState, position.marginForOne);

        uint256 releaseAmount;
        (releaseAmount, repayAmount) = position.update(borrowCumulativeLast, depositCumulativeLast, 0, 0, 0, debtAmount);
        if (profit != releaseAmount) {
            InsufficientReceived.selector.revertWith();
        }

        uint256 lostAmount;
        uint256 fundAmount;
        if (debtAmount > needPayAmount) {
            lostAmount = debtAmount - needPayAmount;
        } else {
            fundAmount = needPayAmount - debtAmount;
        }
        MarginBalanceDelta memory balanceDelta;
        balanceDelta.lendDelta = _toPoolDelta(position.marginForOne, 0, releaseAmount.toInt128());
        balanceDelta.mirrorDelta = _toPoolDelta(position.marginForOne, debtAmount.toInt128(), 0);
        balanceDelta.fundsDelta = _toPoolDelta(
            position.marginForOne, lostAmount > 0 ? -lostAmount.toInt128() : fundAmount.toInt128(), 0
        );
        balanceDelta.action = MarginActions.LIQUIDATE_CALL;
        balanceDelta.marginForOne = position.marginForOne;
        balanceDelta.marginDelta =
            _toPoolDelta(position.marginForOne, -needPayAmount.toInt128(), releaseAmount.toInt128());

        vault.unlock(abi.encode(key, balanceDelta, msg.sender, recipient));
        _clearNative(msg.sender);

        emit LiquidateCall(
            poolId,
            owner,
            salt,
            msg.sender,
            marginAmount,
            marginTotal,
            debtAmount,
            poolState.truncatedReserves,
            poolState.pairReserves,
            releaseAmount,
            repayAmount,
            needPayAmount,
            lostAmount,
            fundAmount
        );
    }

    /// @inheritdoc IMarginCore
    function liquidateBurn(PoolKey calldata key, address owner, bytes32 salt, address recipient, uint256 deadline)
        external
        returns (uint256 profit)
    {
        _ensure(deadline);
        PoolId poolId = key.toId();
        PoolState memory poolState = CurrentStateLibrary.getState(vault, poolId);
        MarginPosition.State storage position = positions[poolId][_positionKey(owner, salt)];

        (bool liquidated, uint256 marginAmount, uint256 marginTotal, uint256 debtAmount) =
            _checkLiquidate(poolState, position);

        if (!liquidated) {
            PositionNotLiquidated.selector.revertWith();
        }
        uint256 assetsAmount = marginAmount + marginTotal;
        profit = assetsAmount.mulDivMillion(marginLevels.callerProfit());

        uint256 releaseAmount;
        uint256 repayAmount;
        uint256 lostAmount;
        uint256 closeAmount;
        Reserves pairReserves = poolState.pairReserves;
        Reserves truncatedReserves = poolState.truncatedReserves;
        uint24 lpFee = poolState.lpFee;
        {
            uint256 swapFeeAmount;
            (uint256 borrowCumulativeLast, uint256 depositCumulativeLast) =
                _getPoolCumulativeValues(poolState, position.marginForOne);

            (releaseAmount, repayAmount, closeAmount, lostAmount, swapFeeAmount) = position.close(
                pairReserves,
                truncatedReserves,
                lpFee,
                borrowCumulativeLast,
                depositCumulativeLast,
                profit,
                uint24(PerLibrary.ONE_MILLION)
            );
            MarginBalanceDelta memory balanceDelta;
            balanceDelta.swapFeeAmount = swapFeeAmount;

            if (position.marginForOne) {
                balanceDelta.marginDelta = toBalanceDelta(0, profit.toInt128());
                balanceDelta.lendDelta = toBalanceDelta(0, (releaseAmount + profit).toInt128());
                balanceDelta.mirrorDelta = toBalanceDelta(repayAmount.toInt128(), 0);
                balanceDelta.pairDelta =
                    toBalanceDelta((repayAmount - lostAmount).toInt128(), -(releaseAmount - closeAmount).toInt128());
                balanceDelta.fundsDelta = toBalanceDelta(-lostAmount.toInt128(), closeAmount.toInt128());
            } else {
                balanceDelta.marginDelta = toBalanceDelta(profit.toInt128(), 0);
                balanceDelta.lendDelta = toBalanceDelta((releaseAmount + profit).toInt128(), 0);
                balanceDelta.mirrorDelta = toBalanceDelta(0, repayAmount.toInt128());
                balanceDelta.pairDelta =
                    toBalanceDelta(-(releaseAmount - closeAmount).toInt128(), (repayAmount - lostAmount).toInt128());
                balanceDelta.fundsDelta = toBalanceDelta(closeAmount.toInt128(), -lostAmount.toInt128());
            }
            balanceDelta.action = MarginActions.LIQUIDATE_BURN;
            balanceDelta.marginForOne = position.marginForOne;

            vault.unlock(abi.encode(key, balanceDelta, address(this), recipient));
        }

        emit LiquidateBurn(
            poolId,
            owner,
            salt,
            msg.sender,
            marginAmount,
            marginTotal,
            debtAmount,
            truncatedReserves,
            pairReserves,
            releaseAmount,
            repayAmount,
            profit,
            lostAmount,
            closeAmount
        );
    }

    /// @dev Executes a liquidation inside the vault unlock: applies the margin balance to the pool,
    /// settles what the payer owes and takes what the recipient is due.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (PoolKey memory key, MarginBalanceDelta memory params, address payer, address recipient) =
            abi.decode(data, (PoolKey, MarginBalanceDelta, address, address));

        BalanceDelta delta = vault.marginBalance(key, params);

        int128 amount0 = delta.amount0();
        if (amount0 < 0) {
            key.currency0.settle(vault, payer, uint128(-amount0), false);
        }
        int128 amount1 = delta.amount1();
        if (amount1 < 0) {
            key.currency1.settle(vault, payer, uint128(-amount1), false);
        }
        _takePositives(key, delta, recipient);

        return "";
    }

    /// @dev Reorders a (borrow currency, margin currency) amount pair into (amount0, amount1).
    /// When marginForOne is true the margin currency is currency1, otherwise currency0.
    function _toPoolDelta(bool marginForOne, int128 borrowSideAmount, int128 marginSideAmount)
        internal
        pure
        returns (BalanceDelta)
    {
        return marginForOne
            ? toBalanceDelta(borrowSideAmount, marginSideAmount)
            : toBalanceDelta(marginSideAmount, borrowSideAmount);
    }

    function _positionKey(address owner, bytes32 salt) internal pure returns (bytes32) {
        return PositionLibrary.calculatePositionKey(owner, salt);
    }

    /// @dev Sends the positive legs of a balance delta from the vault to the recipient.
    /// The negative legs stay on this contract's vault tab and must be settled via
    /// vault.settleFor(address(this)) before the surrounding unlock ends.
    function _takePositives(PoolKey memory key, BalanceDelta delta, address recipient) internal {
        int128 amount0 = delta.amount0();
        if (amount0 > 0) {
            key.currency0.take(vault, recipient, uint128(amount0), false);
        }
        int128 amount1 = delta.amount1();
        if (amount1 > 0) {
            key.currency1.take(vault, recipient, uint128(amount1), false);
        }
    }

    function _clearNative(address recipient) internal {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            CurrencyLibrary.ADDRESS_ZERO.transfer(recipient, balance);
        }
    }

    /// @dev Gets the last cumulative borrow and deposit values for a given position.
    function _getPoolCumulativeValues(PoolState memory poolState, bool marginForOne)
        private
        pure
        returns (uint256 borrowCumulativeLast, uint256 depositCumulativeLast)
    {
        if (marginForOne) {
            borrowCumulativeLast = poolState.borrow0CumulativeLast;
            depositCumulativeLast = poolState.deposit1CumulativeLast;
        } else {
            borrowCumulativeLast = poolState.borrow1CumulativeLast;
            depositCumulativeLast = poolState.deposit0CumulativeLast;
        }
    }

    /// @inheritdoc IMarginCore
    function positionMarginForOne(PoolId poolId, address owner, bytes32 salt) external view returns (bool) {
        return positions[poolId][_positionKey(owner, salt)].marginForOne;
    }

    /// @inheritdoc IMarginCore
    function checkLiquidate(PoolId poolId, address owner, bytes32 salt)
        external
        view
        returns (bool liquidated, uint256 marginAmount, uint256 marginTotal, uint256 debtAmount)
    {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        MarginPosition.State memory position = positions[poolId][_positionKey(owner, salt)];
        (liquidated, marginAmount, marginTotal, debtAmount) = _checkLiquidate(state, position);
    }

    function _ensure(uint256 deadline) internal view {
        require(deadline == 0 || deadline >= block.timestamp, "EXPIRED");
    }

    function _checkLiquidate(PoolState memory state, MarginPosition.State memory position)
        internal
        view
        returns (bool liquidated, uint256 marginAmount, uint256 marginTotal, uint256 debtAmount)
    {
        (uint256 borrowCumulativeLast, uint256 depositCumulativeLast) =
            _getPoolCumulativeValues(state, position.marginForOne);
        // use truncatedReserves
        uint256 level = position.marginLevel(state.truncatedReserves, borrowCumulativeLast, depositCumulativeLast);
        liquidated = level <= marginLevels.liquidateLevel();
        if (liquidated) {
            (marginAmount, marginTotal, debtAmount) = position.accrue(borrowCumulativeLast, depositCumulativeLast);
        }
    }

    function _checkMinLevel(
        Reserves pairReserves,
        uint256 borrowCumulativeLast,
        uint256 depositCumulativeLast,
        MarginPosition.State memory position,
        uint256 minLevel
    ) internal pure {
        uint256 level = position.marginLevel(pairReserves, borrowCumulativeLast, depositCumulativeLast);
        if (level < minLevel) {
            InvalidLevel.selector.revertWith();
        }
    }

    /// @dev Checks the position level against the pool state as updated by the margin balance.
    function _checkMinLevelAfterOp(PoolId poolId, MarginPosition.State memory position, uint256 minLevel)
        internal
        view
    {
        Reserves pairReserves = StateLibrary.getPairReserves(vault, poolId);
        Reserves truncatedReserves = StateLibrary.getTruncatedReserves(vault, poolId);
        uint256 pairLevel = position.marginLevel(pairReserves);
        uint256 truncatedLevel = position.marginLevel(truncatedReserves);
        uint256 level = Math.min(pairLevel, truncatedLevel);
        if (level < minLevel) {
            InvalidLevel.selector.revertWith();
        }
    }

    receive() external payable {}

    // ******************** OWNER CALL ********************
    function setMarginLevel(bytes32 _marginLevel) external onlyOwner {
        MarginLevels newMarginLevels = MarginLevels.wrap(_marginLevel);
        if (!newMarginLevels.isValidMarginLevels()) InvalidLevel.selector.revertWith();
        bytes32 old = MarginLevels.unwrap(marginLevels);
        marginLevels = newMarginLevels;
        emit MarginLevelChanged(old, _marginLevel);
    }
}
