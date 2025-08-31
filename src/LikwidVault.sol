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
        if (!unlocked) ManagerLocked.selector.revertWith();
        _;
    }

    modifier onlyManager() {
        require(msg.sender == marginController, "UNAUTHORIZED");
        _;
    }

    constructor(address initialOwner) ProtocolFees(initialOwner) {
        rateState = rateState.setRateBase(50000).setUseMiddleLevel(400000).setUseHighLevel(800000).setMLow(10)
            .setMMiddle(100).setMHigh(10000);
        protocolFeeController = initialOwner;
    }

    function unlock(bytes calldata data) external override returns (bytes memory result) {
        if (unlocked) revert AlreadyUnlocked();

        unlocked = true;

        // the caller does everything in this callback, including paying what they owe via calls to settle
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        if (nonzeroDeltaCount != 0) revert CurrencyNotSettled();
        unlocked = false;
    }

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

    function modifyLiquidity(PoolKey memory key, IVault.ModifyLiquidityParams memory params)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta callerDelta)
    {
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(key);
        pool.checkPoolInitialized();
        if (params.liquidityDelta > 0) {
            _lockLiquidity(id, uint256(params.liquidityDelta));
        } else if (stageDuration * stageSize > 0) {
            uint256 liquidityRemoved = uint256(-params.liquidityDelta);
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

        callerDelta = pool.modifyLiquidity(
            Pool.ModifyLiquidityParams({
                owner: msg.sender,
                amount0: params.amount0,
                amount1: params.amount1,
                liquidityDelta: params.liquidityDelta.toInt128(),
                salt: params.salt
            })
        );
        emit ModifyLiquidity(id, msg.sender, BalanceDelta.unwrap(callerDelta), params.liquidityDelta, params.salt);
        _appendPoolBalanceDelta(key, msg.sender, callerDelta);
    }

    function swap(PoolKey memory key, IVault.SwapParams memory params)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta swapDelta, uint24 swapFee, uint256 feeAmount)
    {
        if (params.amountSpecified == 0) AmountCannotBeZero.selector.revertWith();

        PoolId id = key.toId();
        Pool.State storage pool = _getPool(key);
        pool.checkPoolInitialized();
        uint256 amountToProtocol;
        (swapDelta, amountToProtocol, swapFee, feeAmount) = pool.swap(
            Pool.SwapParams({
                sender: msg.sender,
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                useMirror: params.useMirror
            })
        );

        _appendPoolBalanceDelta(key, msg.sender, swapDelta);

        if (feeAmount > 0) {
            Currency feeCurrency = params.zeroForOne ? key.currency0 : key.currency1;
            if (amountToProtocol > 0) {
                _updateProtocolFees(feeCurrency, amountToProtocol);
            }
            emit Fees(id, feeCurrency, msg.sender, uint8(FeeType.SWAP), feeAmount);
        }

        emit Swap(id, msg.sender, swapDelta.amount0(), swapDelta.amount1(), pool.slot0.totalSupply(), swapFee);
    }

    function lend(PoolKey memory key, IVault.LendParams memory params)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta lendingDelta)
    {
        if (params.lendAmount == 0) AmountCannotBeZero.selector.revertWith();

        PoolId id = key.toId();
        Pool.State storage pool = _getPool(key);
        pool.checkPoolInitialized();
        uint256 depositCumulativeLast;
        (lendingDelta, depositCumulativeLast) = pool.lend(
            Pool.LendParams({
                sender: msg.sender,
                lendForOne: params.lendForOne,
                lendAmount: params.lendAmount,
                salt: params.salt
            })
        );

        _appendPoolBalanceDelta(key, msg.sender, lendingDelta);

        emit Lending(id, msg.sender, params.lendForOne, params.lendAmount, depositCumulativeLast, params.salt);
    }

    function margin(PoolKey memory key, IVault.MarginParams memory params)
        external
        onlyWhenUnlocked
        noDelegateCall
        onlyManager
        returns (BalanceDelta marginDelta, uint256 feeAmount)
    {
        if (params.amount == 0) AmountCannotBeZero.selector.revertWith();

        PoolId id = key.toId();
        Pool.State storage pool = _getPool(key);
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

    function close(PoolKey memory key, IVault.CloseParams memory params)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta closeDelta)
    {
        if (params.closeMillionth == 0) AmountCannotBeZero.selector.revertWith();

        PoolId id = key.toId();
        Pool.State storage pool = _getPool(key);
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

    function take(Currency currency, address to, uint256 amount) external onlyWhenUnlocked {
        unchecked {
            // negation must be safe as amount is not negative
            _appendDelta(currency, msg.sender, -amount.toInt256());
            currency.transfer(to, amount);
        }
    }

    function settle() external payable onlyWhenUnlocked returns (uint256) {
        return _settle(msg.sender);
    }

    function settleFor(address recipient) external payable onlyWhenUnlocked returns (uint256) {
        return _settle(recipient);
    }

    function clear(Currency currency, uint256 amount) external onlyWhenUnlocked {
        int256 current = currency.currentDelta(msg.sender);
        int256 amountDelta = amount.toInt256();
        if (amountDelta != current) revert MustClearExactPositiveDelta();
        // negation must be safe as amountDelta is positive
        unchecked {
            _appendDelta(currency, msg.sender, -(amountDelta));
        }
    }

    function mint(address to, uint256 id, uint256 amount) external onlyWhenUnlocked {
        unchecked {
            Currency currency = CurrencyLibrary.fromId(id);
            // negation must be safe as amount is not negative
            _appendDelta(currency, msg.sender, -amount.toInt256());
            _mint(to, currency.toId(), amount);
        }
    }

    function burn(address from, uint256 id, uint256 amount) external onlyWhenUnlocked {
        Currency currency = CurrencyLibrary.fromId(id);
        _appendDelta(currency, msg.sender, amount.toInt256());
        _burnFrom(from, currency.toId(), amount);
    }

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
    function _appendPoolBalanceDelta(PoolKey memory key, address target, BalanceDelta delta) internal {
        _appendDelta(key.currency0, target, delta.amount0());
        _appendDelta(key.currency1, target, delta.amount1());
    }

    /// @notice Implementation of the _getPool function defined in ProtocolFees
    function _getPool(PoolKey memory key) internal override returns (Pool.State storage _pool) {
        PoolId id = key.toId();
        _pool = _pools[id];
        (uint256 pairInterest0, uint256 pairInterest1) = _pool.updateInterests(rateState);
        if (pairInterest0 > 0) {
            emit Fees(id, key.currency0, address(this), uint8(FeeType.INTERESTS), pairInterest0);
        }
        if (pairInterest1 > 0) {
            emit Fees(id, key.currency1, address(this), uint8(FeeType.INTERESTS), pairInterest1);
        }
    }

    /// @notice Implementation of the _isUnlocked function defined in ProtocolFees
    function _isUnlocked() internal view override returns (bool) {
        return unlocked;
    }

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
    function setMarginController(address controller) external onlyOwner {
        marginController = controller;
        emit MarginControllerUpdated(controller);
    }

    function setStageDuration(uint32 _stageDuration) external onlyOwner {
        stageDuration = _stageDuration;
    }

    function setStageSize(uint32 _stageSize) external onlyOwner {
        stageSize = _stageSize;
    }

    function setStageLeavePart(uint32 _stageLeavePart) external onlyOwner {
        stageLeavePart = _stageLeavePart;
    }
}
