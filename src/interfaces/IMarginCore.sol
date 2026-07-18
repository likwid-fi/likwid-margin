// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "../types/PoolId.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {Reserves} from "../types/Reserves.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {MarginLevels} from "../types/MarginLevels.sol";
import {MarginPosition} from "../libraries/MarginPosition.sol";

/// @title IMarginCore
/// @notice The margin core owns the margin position ledger and is the vault's sole margin controller.
/// Any contract may open and manage positions scoped to its own address; liquidation is permissionless.
interface IMarginCore {
    /// @notice Thrown when the provided level is invalid
    error InvalidLevel();

    /// @notice Thrown when the received close amount is insufficient
    error InsufficientCloseReceived();

    /// @notice Thrown when the received amount is insufficient
    error InsufficientReceived();

    /// @notice Thrown when the position is already liquidated
    error PositionLiquidated();

    /// @notice Thrown when the position is not liquidated
    error PositionNotLiquidated();

    /// @notice Thrown when the mirror amount is too high
    error MirrorTooMuch();

    /// @notice Thrown when the borrow amount is too high
    error BorrowTooMuch();

    /// @notice Thrown when the reserves are not enough
    error ReservesNotEnough();

    /// @notice Thrown when margin is banned for low fee pools
    error LowFeePoolMarginBanned();

    /// @notice Thrown when the margin is below the minimum required
    error MarginBelowMinimum();

    /// @notice Thrown when the leverage exceeds the maximum allowed
    error ExceedMaxLeverage();

    /// @notice Thrown when the borrow amount exceeds the maximum allowed
    error ExceedBorrowAmountMax();

    /// @notice Thrown when transferring a position to a non-empty target slot
    error PositionOccupied();

    /// @notice Thrown when transferring an empty position
    error PositionEmpty();

    /// @notice Thrown when the recipient contract rejects a pushed position transfer
    error PositionTransferRejected();

    /// @notice Thrown when adding to an existing position with the opposite direction
    error DirectionMismatch();

    /// @notice Emitted when the margin level is changed
    event MarginLevelChanged(bytes32 oldLevel, bytes32 newLevel);

    /// @notice Emitted when a margin position is created or increased
    event Margin(
        PoolId indexed poolId,
        address indexed owner,
        bytes32 indexed salt,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        bool marginForOne
    );

    /// @notice Emitted when a margin position is repaid
    event Repay(
        PoolId indexed poolId,
        address indexed owner,
        bytes32 indexed salt,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        uint256 releaseAmount,
        uint256 repayAmount
    );

    /// @notice Emitted when a margin position is closed
    event Close(
        PoolId indexed poolId,
        address indexed owner,
        bytes32 indexed salt,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        uint256 releaseAmount,
        uint256 repayAmount,
        uint256 closeAmount
    );

    /// @notice Emitted when a margin position is transferred to a new owner
    event TransferPosition(
        PoolId indexed poolId, address indexed owner, bytes32 salt, address indexed newOwner, bytes32 newSalt
    );

    /// @notice Emitted when a margin position is modified
    event Modify(
        PoolId indexed poolId,
        address indexed owner,
        bytes32 indexed salt,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        int256 changeAmount
    );

    /// @notice Emitted when a margin position is liquidated by burning
    event LiquidateBurn(
        PoolId indexed poolId,
        address indexed owner,
        bytes32 indexed salt,
        address sender,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        Reserves truncatedReserves,
        Reserves pairReserves,
        uint256 releaseAmount,
        uint256 repayAmount,
        uint256 profitAmount,
        uint256 lostAmount,
        uint256 fundAmount
    );

    /// @notice Emitted when a margin position is liquidated by repaying its debt
    event LiquidateCall(
        PoolId indexed poolId,
        address indexed owner,
        bytes32 indexed salt,
        address sender,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        Reserves truncatedReserves,
        Reserves pairReserves,
        uint256 releaseAmount,
        uint256 repayAmount,
        uint256 needRepayAmount,
        uint256 lostAmount,
        uint256 fundAmount
    );

    struct MarginParams {
        /// @notice Distinguishes positions of the same owner
        bytes32 salt;
        /// @notice true: currency1 is marginToken, false: currency0 is marginToken. Only read when the position is empty.
        bool marginForOne;
        /// @notice Leverage factor; 0 means collateral-and-borrow mode
        uint24 leverage;
        /// @notice The amount of margin the owner deposits
        uint256 marginAmount;
        /// @notice The borrow amount; 0 to let the pool derive it (leverage mode)
        uint256 borrowAmount;
        /// @notice The maximum acceptable borrow amount; 0 to skip the check
        uint256 borrowAmountMax;
        /// @notice Receiver of any currency the position pays out (borrowed tokens)
        address recipient;
    }

    /// @notice Open or increase a margin position owned by msg.sender.
    /// @dev Must be called inside a vault unlock. Currency the position pays out is taken to
    /// params.recipient; the returned delta's negative legs are left on this contract's vault tab
    /// and MUST be settled by the caller via vault.settleFor(address(this)) before the unlock ends.
    /// @return borrowAmount The resulting borrow amount
    /// @return swapFeeAmount The swap fee amount charged inside the margin swap
    /// @return delta The position's balance delta (negative legs = amounts the caller owes the vault)
    function margin(PoolKey calldata key, MarginParams calldata params)
        external
        returns (uint256 borrowAmount, uint256 swapFeeAmount, BalanceDelta delta);

    /// @notice Repay debt of a position owned by msg.sender.
    /// @dev Must be called inside a vault unlock; same settlement contract as margin().
    /// @return releaseAmount The margin amount released to params recipient
    /// @return realRepayAmount The debt actually repaid (owed by the caller)
    /// @return delta The position's balance delta
    function repay(PoolKey calldata key, bytes32 salt, uint256 repayAmount, address recipient)
        external
        returns (uint256 releaseAmount, uint256 realRepayAmount, BalanceDelta delta);

    /// @notice Close (part of) a position owned by msg.sender by swapping margin back to the debt currency.
    /// @dev Must be called inside a vault unlock. No caller settlement needed; proceeds go to recipient.
    /// @return closeAmount The margin currency amount received after closing
    /// @return delta The position's balance delta
    function close(PoolKey calldata key, bytes32 salt, uint24 closeMillionth, uint256 closeAmountMin, address recipient)
        external
        returns (uint256 closeAmount, BalanceDelta delta);

    /// @notice Add (changeAmount > 0) or withdraw (changeAmount < 0) margin of a position owned by msg.sender.
    /// @dev Must be called inside a vault unlock; same settlement contract as margin().
    /// @return delta The position's balance delta
    function modify(PoolKey calldata key, bytes32 salt, int128 changeAmount, address recipient)
        external
        returns (BalanceDelta delta);

    /// @notice Transfer a position owned by msg.sender to a new owner (collateral and debt together).
    /// @dev Pure ledger move; no vault interaction, callable outside an unlock. The target slot
    /// must be empty. The caller is responsible for choosing a receiver able to manage the position.
    /// @param key The pool key
    /// @param salt The position salt under msg.sender
    /// @param newOwner The new position owner
    /// @param newSalt The position salt under the new owner
    function transferPosition(PoolKey calldata key, bytes32 salt, address newOwner, bytes32 newSalt) external;

    /// @notice Permissionlessly liquidate an unhealthy position by closing it through the pool.
    /// @dev Self-contained: initiates its own vault unlock; callable by anyone on any position.
    /// @param key The pool key
    /// @param owner The position owner
    /// @param salt The position salt
    /// @param recipient Receiver of the caller profit
    /// @param deadline Latest timestamp the liquidation may execute (0 to disable)
    /// @return profit The caller profit amount (margin currency)
    function liquidateBurn(PoolKey calldata key, address owner, bytes32 salt, address recipient, uint256 deadline)
        external
        returns (uint256 profit);

    /// @notice Permissionlessly liquidate an unhealthy position by repaying its debt at a discount.
    /// @dev Self-contained: initiates its own vault unlock. The caller pays the discounted debt
    /// (ERC20 allowance to this contract, or msg.value for native) and receives the position's assets.
    /// @param key The pool key
    /// @param owner The position owner
    /// @param salt The position salt
    /// @param recipient Receiver of the position's assets
    /// @param deadline Latest timestamp the liquidation may execute (0 to disable)
    /// @return profit The released position value (margin currency)
    /// @return repayAmount The debt repaid
    function liquidateCall(PoolKey calldata key, address owner, bytes32 salt, address recipient, uint256 deadline)
        external
        payable
        returns (uint256 profit, uint256 repayAmount);

    /// @notice Gets a position with interest accrued to now
    function getPositionState(PoolId poolId, address owner, bytes32 salt)
        external
        view
        returns (MarginPosition.State memory position);

    /// @notice The stored direction of a position (raw, no interest accrual)
    function positionMarginForOne(PoolId poolId, address owner, bytes32 salt) external view returns (bool);

    /// @notice Whether a position is currently liquidatable
    function checkLiquidate(PoolId poolId, address owner, bytes32 salt)
        external
        view
        returns (bool liquidated, uint256 marginAmount, uint256 marginTotal, uint256 debtAmount);

    /// @notice Gets the margin levels configuration
    function marginLevels() external view returns (MarginLevels marginLevel);
}
