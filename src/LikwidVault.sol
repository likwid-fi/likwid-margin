// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";

import {Currency, CurrencyLibrary} from "./types/Currency.sol";
import {PoolKey} from "./types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "./types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "./types/BeforeSwapDelta.sol";
import {PoolId} from "./types/PoolId.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IUnlockCallback} from "./interfaces/callback/IUnlockCallback.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {CurrencyGuard} from "./libraries/CurrencyGuard.sol";
import {Pool} from "./libraries/Pool.sol";
import {ERC6909Claims} from "./base/ERC6909Claims.sol";
import {NoDelegateCall} from "./base/NoDelegateCall.sol";
import {ProtocolFees} from "./base/ProtocolFees.sol";

/// @title Likwid vault
/// @notice Holds the property for all likwid pools
contract LikwidVault is IVault, ProtocolFees, NoDelegateCall, ERC6909Claims {
    using CustomRevert for bytes4;
    using SafeCast for *;
    using CurrencyGuard for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using Pool for Pool.State;

    error NotImplemented();

    mapping(PoolId id => Pool.State) private _pools;

    /// transient storage
    bool transient unlocked;
    uint256 transient nonzeroDeltaCount;

    /// @notice This will revert if the contract is locked
    modifier onlyWhenUnlocked() {
        if (!unlocked) revert ManagerLocked();
        _;
    }

    constructor(address initialOwner) ProtocolFees(initialOwner) {}

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

    function modifyLiquidity(PoolKey memory key, IVault.ModifyLiquidityParams memory params, bytes calldata)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta callerDelta)
    {
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);
        pool.checkPoolInitialized();

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

    function swap(PoolKey memory, IVault.SwapParams memory params, bytes calldata)
        external
        view
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta)
    {
        if (params.amountSpecified == 0) revert SwapAmountCannotBeZero();
        revert NotImplemented();
    }

    function donate(PoolKey memory, uint256, uint256, bytes calldata)
        external
        view
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta)
    {
        revert NotImplemented();
    }

    function updateDynamicLPFee(PoolKey memory, uint24) external pure {
        revert NotImplemented();
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
    function _getPool(PoolId id) internal view override returns (Pool.State storage) {
        return _pools[id];
    }

    /// @notice Implementation of the _isUnlocked function defined in ProtocolFees
    function _isUnlocked() internal view override returns (bool) {
        return unlocked;
    }
}
