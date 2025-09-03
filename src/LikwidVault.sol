// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";

import {Currency, CurrencyLibrary} from "./types/Currency.sol";
import {PoolKey} from "./types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "./types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "./types/BeforeSwapDelta.sol";
import {PoolId} from "./types/PoolId.sol";
import {FeeType} from "./types/FeeType.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IUnlockCallback} from "./interfaces/callback/IUnlockCallback.sol";
import {DoubleEndedQueue} from "./libraries/external/DoubleEndedQueue.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {CurrencyGuard} from "./libraries/CurrencyGuard.sol";
import {Pool} from "./libraries/Pool.sol";
import {MarginPosition} from "./libraries/MarginPosition.sol";
import {ERC6909Claims} from "./base/ERC6909Claims.sol";
import {NoDelegateCall} from "./base/NoDelegateCall.sol";
import {ProtocolFees} from "./base/ProtocolFees.sol";
import {Extsload} from "./base/Extsload.sol";
import {Exttload} from "./base/Exttload.sol";
import {Math} from "./libraries/Math.sol";
import {StageMath} from "./libraries/StageMath.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";

/// @title Likwid vault
/// @notice Holds the property for all likwid pools
contract LikwidVault is IVault, ProtocolFees, NoDelegateCall, ERC6909Claims, Extsload, Exttload {
    using CustomRevert for bytes4;
    using SafeCast for *;
    using DoubleEndedQueue for DoubleEndedQueue.Uint256Deque;
    using StageMath for uint256;
    using CurrencyGuard for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using Pool for Pool.State;

    error LiquidityLocked();
    error Unauthorized();

    mapping(PoolId id => Pool.State) private _pools;
    address public marginController;

    uint32 public stageDuration = 1 hours; // default: 1 hour seconds
    uint32 public stageSize = 5; // default: 5 stages
    uint32 public stageLeavePart = 5; // default: 5, meaning 20% of the total liquidity is free
    mapping(PoolId id => uint256) public lastStageTimestampStore; // Timestamp of the last stage
    mapping(PoolId id => DoubleEndedQueue.Uint256Deque) liquidityLockedQueue;

    /// transient storage
    bool transient unlocked;
    uint256 transient nonzeroDeltaCount;

    /// @notice This will revert if the contract is locked
    modifier onlyWhenUnlocked() {
        if (!unlocked) VaultLocked.selector.revertWith();
        _;
    }

    modifier onlyManager() {
        if (msg.sender != marginController) Unauthorized.selector.revertWith();
        _;
    }

    uint24 private constant MAX_PRICE_MOVE_PER_SECOND = 3000; // 0.3%/second
    uint24 private constant RATE_BASE = 50000;
    uint24 private constant USE_MIDDLE_LEVEL = 400000;
    uint24 private constant USE_HIGH_LEVEL = 800000;
    uint24 private constant M_LOW = 10;
    uint24 private constant M_MIDDLE = 100;
    uint24 private constant M_HIGH = 10000;

    constructor(address initialOwner) ProtocolFees(initialOwner) {
        marginState = marginState.setMaxPriceMovePerSecond(MAX_PRICE_MOVE_PER_SECOND).setRateBase(RATE_BASE)
            .setUseMiddleLevel(USE_MIDDLE_LEVEL).setUseHighLevel(USE_HIGH_LEVEL).setMLow(M_LOW).setMMiddle(M_MIDDLE)
            .setMHigh(M_HIGH);
        protocolFeeController = initialOwner;
    }

    /// @notice Unlocks the contract for a single transaction.
    /// @dev This function is called by an external contract to perform a series of actions within the vault.
    /// The vault is locked by default and this function temporarily unlocks it.
    /// It requires a callback to the sender, which will perform the desired actions.
    /// After the callback is finished, the vault is locked again.
    /// @param data The data to be passed to the callback function.
    /// @return result The data returned by the callback function.
    function unlock(bytes calldata data) external override returns (bytes memory result) {
        if (unlocked) revert AlreadyUnlocked();

        unlocked = true;

        // the caller does everything in this callback, including paying what they owe via calls to settle
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        if (nonzeroDeltaCount != 0) revert CurrencyNotSettled();
        unlocked = false;
    }

    /// @notice Initializes a new pool.
    /// @dev Creates a new liquidity pool for a pair of currencies. The currencies must be provided in a specific order.
    /// @param key The key of the pool to initialize, containing the two currencies and the fee.
    function initialize(PoolKey memory key) external noDelegateCall {
        if (key.currency0 >= key.currency1) {
            CurrenciesOutOfOrderOrEqual.selector.revertWith(
                Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)
            );
        }

        // likwid pools are initialized with tick = 1
        PoolId id = key.toId();
        _pools[id].initialize(key.fee);
        emit Initialize(id, key.currency0, key.currency1, key.fee);
    }

    /// @notice Modifies liquidity in a pool.
    /// @dev Adds or removes liquidity from a pool. The caller must be authorized.
    /// @param key The key of the pool to modify.
    /// @param params The parameters for modifying liquidity, including the amount of liquidity to add or remove.
    /// @return callerDelta The change in the caller's balance.
    function modifyLiquidity(PoolKey memory key, IVault.ModifyLiquidityParams memory params)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta callerDelta, int128 finalLiquidityDelta)
    {
        Pool.State storage pool = _getAndUpdatePool(key);
        pool.checkPoolInitialized();
        PoolId id = key.toId();

        uint256 liquidityBefore = pool.slot0.totalSupply();

        (callerDelta, finalLiquidityDelta) = pool.modifyLiquidity(
            Pool.ModifyLiquidityParams({
                owner: msg.sender,
                amount0: params.amount0,
                amount1: params.amount1,
                liquidityDelta: params.liquidityDelta.toInt128(),
                salt: params.salt
            })
        );

        uint256 liquidityAfter = pool.slot0.totalSupply();

        if (liquidityAfter > liquidityBefore) {
            _handleAddLiquidity(id, liquidityAfter - liquidityBefore);
        } else if (liquidityAfter < liquidityBefore) {
            _handleRemoveLiquidity(id, liquidityBefore - liquidityAfter);
        }
        emit ModifyLiquidity(id, msg.sender, BalanceDelta.unwrap(callerDelta), params.liquidityDelta, params.salt);
        _appendPoolBalanceDelta(key, msg.sender, callerDelta);
    }

    /// @notice Handles the addition of liquidity to a pool.
    /// @dev Locks the liquidity according to the staging mechanism.
    /// @param id The ID of the pool.
    /// @param liquidityAdded The amount of liquidity to add.
    function _handleAddLiquidity(PoolId id, uint256 liquidityAdded) internal {
        _lockLiquidity(id, liquidityAdded);
    }

    /// @notice Handles the removal of liquidity from a pool.
    /// @dev Checks if the requested amount of liquidity is available for withdrawal and updates the liquidity queue.
    /// @param id The ID of the pool.
    /// @param liquidityRemoved The amount of liquidity to remove .
    function _handleRemoveLiquidity(PoolId id, uint256 liquidityRemoved) internal {
        if (stageDuration * stageSize > 0) {
            (uint128 releasedLiquidity, uint128 nextReleasedLiquidity) = _getReleasedLiquidity(id);
            uint256 availableLiquidity = releasedLiquidity + nextReleasedLiquidity;
            if (availableLiquidity < liquidityRemoved) {
                LiquidityLocked.selector.revertWith();
            }
            DoubleEndedQueue.Uint256Deque storage queue = liquidityLockedQueue[id];
            if (!queue.empty()) {
                if (nextReleasedLiquidity > 0) {
                    // If next stage is free, we can release the next stage liquidity
                    uint256 currentStage = queue.popFront(); // Remove the current stage
                    uint256 nextStage = queue.front();
                    (, uint128 currentLiquidity) = currentStage.decode();
                    if (currentLiquidity > liquidityRemoved) {
                        nextStage = nextStage.add((currentLiquidity - liquidityRemoved).toUint128());
                    } else {
                        nextStage = nextStage.sub((liquidityRemoved - currentLiquidity).toUint128());
                    }
                    queue.set(0, nextStage);
                    // Update lastStageTimestamp to the next stage time
                    lastStageTimestampStore[id] = block.timestamp;
                } else {
                    // If next stage is not free, we just reduce the current stage liquidity
                    uint256 currentStage = queue.front();
                    uint256 afterStage;
                    if (queue.length() == 1) {
                        afterStage = currentStage.subTotal(liquidityRemoved.toUint128());
                    } else {
                        afterStage = currentStage.sub(liquidityRemoved.toUint128());
                    }
                    if (!currentStage.isFree(stageLeavePart) || queue.length() == 1) {
                        // Update lastStageTimestamp
                        lastStageTimestampStore[id] = block.timestamp;
                    }
                    queue.set(0, afterStage);
                }
            }
        }
    }

    /// @notice Swaps tokens in a pool.
    /// @dev Executes a token swap in the specified pool.
    /// @param key The key of the pool to swap in.
    /// @param params The parameters for the swap, including the amount and direction of the swap.
    /// @return swapDelta The change in the caller's balance.
    /// @return swapFee The fee applied to the swap.
    /// @return feeAmount The amount of the fee.
    function swap(PoolKey memory key, IVault.SwapParams memory params)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta swapDelta, uint24 swapFee, uint256 feeAmount)
    {
        if (params.amountSpecified == 0) AmountCannotBeZero.selector.revertWith();

        PoolId id = key.toId();
        Pool.State storage pool = _getAndUpdatePool(key);
        pool.checkPoolInitialized();
        uint256 amountToProtocol;
        (swapDelta, amountToProtocol, swapFee, feeAmount) = pool.swap(
            Pool.SwapParams({
                sender: msg.sender,
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                useMirror: params.useMirror,
                salt: params.salt
            })
        );
        if (params.useMirror) {
            BalanceDelta realDelta;
            if (params.zeroForOne) {
                realDelta = toBalanceDelta(swapDelta.amount0(), 0);
            } else {
                realDelta = toBalanceDelta(0, swapDelta.amount1());
            }
            _appendPoolBalanceDelta(key, msg.sender, realDelta);
        } else {
            _appendPoolBalanceDelta(key, msg.sender, swapDelta);
        }

        if (feeAmount > 0) {
            Currency feeCurrency = params.zeroForOne ? key.currency0 : key.currency1;
            if (amountToProtocol > 0) {
                _updateProtocolFees(feeCurrency, amountToProtocol);
            }
            emit Fees(id, feeCurrency, msg.sender, uint8(FeeType.SWAP), feeAmount);
        }

        emit Swap(id, msg.sender, swapDelta.amount0(), swapDelta.amount1(), pool.slot0.totalSupply(), swapFee);
    }

    /// @notice Lends tokens to a pool.
    /// @dev Allows a user to lend tokens to a pool and earn interest.
    /// @param key The key of the pool to lend to.
    /// @param params The parameters for the lending operation, including the amount to lend.
    /// @return lendDelta The change in the lender's balance.
    function lend(PoolKey memory key, IVault.LendParams memory params)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta lendDelta)
    {
        if (params.lendAmount == 0) AmountCannotBeZero.selector.revertWith();

        PoolId id = key.toId();
        Pool.State storage pool = _getAndUpdatePool(key);
        pool.checkPoolInitialized();
        uint256 depositCumulativeLast;
        (lendDelta, depositCumulativeLast) = pool.lend(
            Pool.LendParams({
                sender: msg.sender,
                lendForOne: params.lendForOne,
                lendAmount: params.lendAmount,
                salt: params.salt
            })
        );

        _appendPoolBalanceDelta(key, msg.sender, lendDelta);

        emit Lend(id, msg.sender, params.lendForOne, params.lendAmount, depositCumulativeLast, params.salt);
    }

    /// @notice Opens a margin position.
    /// @dev Allows a user to open a margin position, borrowing tokens to leverage their position.
    /// @param key The key of the pool to open the margin position in.
    /// @param params The parameters for the margin position, including the amount and leverage.
    /// @return marginDelta The change in the user's balance.
    /// @return feeAmount The fee charged for opening the margin position.
    function margin(PoolKey memory key, IVault.MarginParams memory params)
        external
        onlyWhenUnlocked
        noDelegateCall
        onlyManager
        returns (BalanceDelta marginDelta, uint256 feeAmount)
    {
        if (params.amount == 0) AmountCannotBeZero.selector.revertWith();

        PoolId id = key.toId();
        Pool.State storage pool = _getAndUpdatePool(key);
        pool.checkPoolInitialized();
        uint256 amountToProtocol;
        (marginDelta, amountToProtocol, feeAmount) = pool.margin(
            Pool.MarginParams({
                sender: msg.sender,
                marginForOne: params.marginForOne,
                amount: params.amount,
                marginTotal: params.marginTotal,
                borrowAmount: params.borrowAmount,
                salt: params.salt
            })
        );

        if (feeAmount > 0) {
            Currency feeCurrency = params.marginForOne ? key.currency1 : key.currency0;
            if (amountToProtocol > 0) {
                _updateProtocolFees(feeCurrency, amountToProtocol);
            }
            emit Fees(id, feeCurrency, msg.sender, uint8(FeeType.MARGIN), feeAmount);
        }

        _appendPoolBalanceDelta(key, msg.sender, marginDelta);

        emit Margin(
            id, msg.sender, params.marginForOne, params.amount, params.marginTotal, params.borrowAmount, params.salt
        );
    }

    /// @notice Closes a margin position.
    /// @dev Allows a user to close an existing margin position.
    /// @param key The key of the pool where the position is held.
    /// @param params The parameters for closing the position.
    /// @return closeDelta The change in the user's balance.
    function close(PoolKey memory key, IVault.CloseParams memory params)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta closeDelta)
    {
        if (params.closeMillionth == 0) AmountCannotBeZero.selector.revertWith();

        PoolId id = key.toId();
        Pool.State storage pool = _getAndUpdatePool(key);
        pool.checkPoolInitialized();
        closeDelta = pool.close(
            Pool.CloseParams({
                sender: msg.sender,
                positionKey: params.positionKey,
                salt: params.salt,
                rewardAmount: params.rewardAmount,
                closeMillionth: params.closeMillionth
            })
        );

        _appendPoolBalanceDelta(key, msg.sender, closeDelta);

        emit Close(id, msg.sender, params.positionKey, params.rewardAmount, params.closeMillionth, params.salt);
    }

    /// @notice Synchronizes the balance of a currency.
    /// @dev Updates the contract's record of its balance for a specific currency.
    /// @param currency The currency to synchronize.
    function sync(Currency currency) external {
        // address(0) is used for the native currency
        if (currency.isAddressZero()) {
            syncedCurrency = CurrencyLibrary.ADDRESS_ZERO;
        } else {
            uint256 balance = currency.balanceOfSelf();
            syncedCurrency = currency;
            syncedReserves = balance;
        }
    }

    /// @notice Takes a specified amount of a currency from the contract.
    /// @dev Allows a user to withdraw a currency from their balance in the contract.
    /// @param currency The currency to take.
    /// @param to The address to send the currency to.
    /// @param amount The amount of the currency to take.
    function take(Currency currency, address to, uint256 amount) external onlyWhenUnlocked {
        unchecked {
            // negation must be safe as amount is not negative
            _appendDelta(currency, msg.sender, -amount.toInt256());
            currency.transfer(to, amount);
        }
    }

    /// @notice Settles the caller's balance.
    /// @dev Allows a user to settle their balance, receiving any due payments.
    /// @return The amount paid to the user.
    function settle() external payable onlyWhenUnlocked returns (uint256) {
        return _settle(msg.sender);
    }

    /// @notice Settles the balance for a specific recipient.
    /// @dev Allows settling the balance on behalf of another address.
    /// @param recipient The address whose balance is to be settled.
    /// @return The amount paid to the recipient.
    function settleFor(address recipient) external payable onlyWhenUnlocked returns (uint256) {
        return _settle(recipient);
    }

    /// @notice Clears a positive balance delta.
    /// @dev Allows a user to clear a positive balance delta they have in a specific currency.
    /// @param currency The currency to clear the delta for.
    /// @param amount The amount of the delta to clear.
    function clear(Currency currency, uint256 amount) external onlyWhenUnlocked {
        int256 current = currency.currentDelta(msg.sender);
        int256 amountDelta = amount.toInt256();
        if (amountDelta != current) revert MustClearExactPositiveDelta();
        // negation must be safe as amountDelta is positive
        unchecked {
            _appendDelta(currency, msg.sender, -(amountDelta));
        }
    }

    /// @notice Mints new tokens.
    /// @dev Mints a specified amount of a token to a given address.
    /// @param to The address to mint the tokens to.
    /// @param id The ID of the token to mint.
    /// @param amount The amount of tokens to mint.
    function mint(address to, uint256 id, uint256 amount) external onlyWhenUnlocked {
        unchecked {
            Currency currency = CurrencyLibrary.fromId(id);
            // negation must be safe as amount is not negative
            _appendDelta(currency, msg.sender, -amount.toInt256());
            _mint(to, currency.toId(), amount);
        }
    }

    /// @notice Burns existing tokens.
    /// @dev Burns a specified amount of a token from a given address.
    /// @param from The address to burn the tokens from.
    /// @param id The ID of the token to burn.
    /// @param amount The amount of tokens to burn.
    function burn(address from, uint256 id, uint256 amount) external onlyWhenUnlocked {
        Currency currency = CurrencyLibrary.fromId(id);
        _appendDelta(currency, msg.sender, amount.toInt256());
        _burnFrom(from, currency.toId(), amount);
    }

    /// @notice Settles a user's balance for a specific currency.
    /// @dev Internal function to handle the logic of settling a user's balance.
    /// @param recipient The address of the user to settle the balance for.
    /// @return paid The amount paid to the user.
    function _settle(address recipient) internal returns (uint256 paid) {
        Currency currency = syncedCurrency;

        if (currency.isAddressZero()) {
            paid = msg.value;
        } else {
            if (msg.value > 0) revert NonzeroNativeValue();
            uint256 reservesBefore = syncedReserves;
            uint256 reservesNow = currency.balanceOfSelf();
            paid = reservesNow - reservesBefore;
            syncedCurrency = CurrencyLibrary.ADDRESS_ZERO; // reset synced currency
        }

        _appendDelta(currency, recipient, paid.toInt256());
    }

    /// @notice Appends a balance delta in a currency for a target address
    /// @param currency The currency to update the balance for.
    /// @param target The address whose balance is to be updated.
    /// @param delta The change in balance.
    function _appendDelta(Currency currency, address target, int256 delta) internal {
        if (delta == 0) return;

        (int256 previous, int256 current) = currency.appendDelta(target, delta.toInt128());

        if (current == 0) {
            nonzeroDeltaCount -= 1;
        } else if (previous == 0) {
            nonzeroDeltaCount += 1;
        }
    }

    /// @notice Appends the deltas of 2 currencies to a target address
    /// @param key The key of the pool.
    /// @param target The address whose balance is to be updated.
    /// @param delta The change in balance for both currencies.
    function _appendPoolBalanceDelta(PoolKey memory key, address target, BalanceDelta delta) internal {
        _appendDelta(key.currency0, target, delta.amount0());
        _appendDelta(key.currency1, target, delta.amount1());
    }

    /// @notice Implementation of the _getAndUpdatePool function defined in ProtocolFees
    /// @param key The key of the pool to retrieve.
    /// @return _pool The state of the pool.
    function _getAndUpdatePool(PoolKey memory key) internal override returns (Pool.State storage _pool) {
        PoolId id = key.toId();
        _pool = _pools[id];
        (uint256 pairInterest0, uint256 pairInterest1) = _pool.updateInterests(marginState);
        if (pairInterest0 > 0) {
            emit Fees(id, key.currency0, address(this), uint8(FeeType.INTERESTS), pairInterest0);
        }
        if (pairInterest1 > 0) {
            emit Fees(id, key.currency1, address(this), uint8(FeeType.INTERESTS), pairInterest1);
        }
    }

    /// @notice Implementation of the _isUnlocked function defined in ProtocolFees
    /// @return A boolean indicating whether the contract is unlocked.
    function _isUnlocked() internal view override returns (bool) {
        return unlocked;
    }

    /// @notice Locks a certain amount of liquidity in stages.
    /// @dev Internal function to manage the staged locking of liquidity.
    /// @param id The ID of the pool.
    /// @param amount The amount of liquidity to lock.
    function _lockLiquidity(PoolId id, uint256 amount) internal {
        if (stageDuration * stageSize == 0) {
            return; // No locking if stageDuration or stageSize is zero
        }
        uint256 lastStageTimestamp = lastStageTimestampStore[id];
        if (lastStageTimestamp == 0) {
            // Initialize lastStageTimestamp if it's not set
            lastStageTimestampStore[id] = block.timestamp;
        }
        DoubleEndedQueue.Uint256Deque storage queue = liquidityLockedQueue[id];
        uint128 lockAmount = Math.ceilDiv(amount, stageSize).toUint128(); // Ensure at least 1 unit is locked per stage
        uint256 zeroStage = 0;
        if (queue.empty()) {
            for (uint32 i = 0; i < stageSize; i++) {
                queue.pushBack(zeroStage.add(lockAmount));
            }
        } else {
            uint256 queueSize = Math.min(queue.length(), stageSize);
            // If the queue is not empty, we need to update the existing stages
            // and add new stages if necessary
            for (uint256 i = 0; i < queueSize; i++) {
                uint256 stage = queue.at(i);
                queue.set(i, stage.add(lockAmount));
            }
            for (uint256 i = queueSize; i < stageSize; i++) {
                queue.pushBack(zeroStage.add(lockAmount));
            }
        }
    }

    /// @notice Gets the amount of released and next-to-be-released liquidity.
    /// @dev Internal view function to calculate the amount of liquidity that is currently released and the amount that will be released in the next stage.
    /// @param id The ID of the pool.
    /// @return releasedLiquidity The amount of liquidity that is currently released.
    /// @return nextReleasedLiquidity The amount of liquidity that will be released in the next stage.
    function _getReleasedLiquidity(PoolId id)
        internal
        view
        returns (uint128 releasedLiquidity, uint128 nextReleasedLiquidity)
    {
        releasedLiquidity = type(uint128).max;
        if (stageDuration * stageSize > 0) {
            DoubleEndedQueue.Uint256Deque storage queue = liquidityLockedQueue[id];
            uint256 lastStageTimestamp = lastStageTimestampStore[id];
            if (!queue.empty()) {
                uint256 currentStage = queue.front();
                uint256 total;
                (total, releasedLiquidity) = currentStage.decode();
                if (
                    queue.length() > 1 && currentStage.isFree(stageLeavePart)
                        && block.timestamp >= lastStageTimestamp + stageDuration
                ) {
                    uint256 nextStage = queue.at(1);
                    (, nextReleasedLiquidity) = nextStage.decode();
                }
            }
        }
    }

    // ******************** OWNER CALL ********************
    /// @notice Sets the margin controller address.
    /// @dev Only the owner can call this function.
    /// @param controller The address of the new margin controller.
    function setMarginController(address controller) external onlyOwner {
        marginController = controller;
        emit MarginControllerUpdated(controller);
    }

    /// @notice Sets the duration of each liquidity stage.
    /// @dev Only the owner can call this function.
    /// @param _stageDuration The new duration for each stage.
    function setStageDuration(uint32 _stageDuration) external onlyOwner {
        stageDuration = _stageDuration;
    }

    /// @notice Sets the number of liquidity stages.
    /// @dev Only the owner can call this function.
    /// @param _stageSize The new number of stages.
    function setStageSize(uint32 _stageSize) external onlyOwner {
        stageSize = _stageSize;
    }

    /// @notice Sets the part of liquidity that is free to leave in each stage.
    /// @dev Only the owner can call this function.
    /// @param _stageLeavePart The new leave part for each stage.
    function setStageLeavePart(uint32 _stageLeavePart) external onlyOwner {
        stageLeavePart = _stageLeavePart;
    }
}
