// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IUnlockCallback } from "lib/v4-periphery/lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { SafeCast } from "lib/v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol"; 
import { ERC6909Claims } from "lib/v4-periphery/lib/v4-core/src/ERC6909Claims.sol";
import { PoolKey } from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import { IHooks, Hooks } from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import { IPoolManager } from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import { BeforeSwapDelta } from "lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import { CurrencyLibrary, Currency } from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";

interface IPoolManagerLight {

    /// @notice Swap against the given pool
    /// @param key The pool to swap in
    /// @param params The parameters for swapping
    /// @param hookData The data to pass through to the swap hooks
    /// @return swapDelta The balance delta of the address swapping
    /// @dev Swapping on low liquidity pools may cause unexpected swap amounts when liquidity available is less than amountSpecified.
    /// Additionally note that if interacting with hooks that have the BEFORE_SWAP_RETURNS_DELTA_FLAG or AFTER_SWAP_RETURNS_DELTA_FLAG
    /// the hook may alter the swap input/output. Integrators should perform checks on the returned swapDelta.
    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta swapDelta);

    /// @notice All interactions on the contract that account deltas require unlocking. A caller that calls `unlock` must implement
    /// `IUnlockCallback(msg.sender).unlockCallback(data)`, where they interact with the remaining functions on this contract.
    /// @dev The only functions callable without an unlocking are `initialize` and `updateDynamicLPFee`
    /// @param data Any data to pass to the callback, via `IUnlockCallback(msg.sender).unlockCallback(data)`
    /// @return The data returned by the call to `IUnlockCallback(msg.sender).unlockCallback(data)`
    function unlock(bytes calldata data) external returns (bytes memory);

    /// @notice Called by the user to move value from ERC6909 balance
    /// @param from The address to burn the tokens from
    /// @param id The currency address to burn from ERC6909s, as a uint256
    /// @param amount The amount of currency to burn
    /// @dev The id is converted to a uint160 to correspond to a currency address
    /// If the upper 12 bytes are not 0, they will be 0-ed out
    function burn(address from, uint256 id, uint256 amount) external;

    /// @notice Initialize the state for a given pool ID
    /// @dev A swap fee totaling MAX_SWAP_FEE (100%) makes exact output swaps impossible since the input is entirely consumed by the fee
    /// @param key The pool key for the pool to initialize
    /// @param sqrtPriceX96 The initial square root price
    /// @return tick The initial tick of the pool
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);

    /// @notice Called by the user to net out some value owed to the user
    /// @dev Will revert if the requested amount is not available, consider using `mint` instead
    /// @dev Can also be used as a mechanism for free flash loans
    /// @param currency The currency to withdraw from the pool manager
    /// @param to The address to withdraw to
    /// @param amount The amount of currency to withdraw
    function take(Currency currency, address to, uint256 amount) external;

    /// @notice Called by the user to pay what is owed
    /// @return paid The amount of currency settled
    function settle() external payable returns (uint256 paid);

    
    /// @notice Called by the user to move value into ERC6909 balance
    /// @param to The address to mint the tokens to
    /// @param id The currency address to mint to ERC6909s, as a uint256
    /// @param amount The amount of currency to mint
    /// @dev The id is converted to a uint160 to correspond to a currency address
    /// If the upper 12 bytes are not 0, they will be 0-ed out
    function mint(address to, uint256 id, uint256 amount) external;

    /// @notice Writes the current ERC20 balance of the specified currency to transient storage
    /// This is used to checkpoint balances for the manager and derive deltas for the caller.
    /// @dev This MUST be called before any ERC20 tokens are sent into the contract, but can be skipped
    /// for native tokens because the amount to settle is determined by the sent value.
    /// However, if an ERC20 token has been synced and not settled, and the caller instead wants to settle
    /// native funds, this function can be called with the native currency to then be able to settle the native currency
    function sync(Currency currency) external;
}

contract PoolManager is IPoolManagerLight, ERC6909Claims {
    using SafeCast for uint256;

    bool private __unlocked;
    address private _synchedCurrency;
    uint256 private _synchedReserves;
    /// Mock for the transient storage in the Pool Manager.
    /// Every successful call to the PM must end with ALL of the mapping values being zero.
    mapping(address /* currency */ => mapping(address /* account */ => int128)) private _currencyDelta;

    /// @notice This will revert if the contract is locked
    modifier onlyWhenUnlocked() {
        if (!__unlocked) revert("Is locked");
        _;
    }

    /// @inheritdoc IPoolManagerLight
    function unlock(bytes calldata data) external override returns (bytes memory result) {
        if (__unlocked) revert("Still unlocked");
        __unlocked = true;

        // the caller does everything in this callback, including paying what they owe via calls to settle
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        __unlocked = false;
    }

    /// @inheritdoc IPoolManagerLight
    function burn(address from, uint256 id, uint256 amount) external onlyWhenUnlocked {
        address currency = Currency.unwrap(CurrencyLibrary.fromId(id));
        _currencyDelta[currency][msg.sender] += amount.toInt128();
        _burnFrom(from, id, amount);
    }

    /// @inheritdoc IPoolManagerLight
    function mint(address to, uint256 id, uint256 amount) external onlyWhenUnlocked {
        address currency = Currency.unwrap(CurrencyLibrary.fromId(id));
        unchecked {
            // negation must be safe as amount is not negative
            _currencyDelta[currency][msg.sender] -= amount.toInt128();
            _mint(to, id, amount);
        }
    }

    /// @inheritdoc IPoolManagerLight
    function take(Currency currency, address to, uint256 amount) external onlyWhenUnlocked {
        unchecked {
            // negation must be safe as amount is not negative
            _currencyDelta[Currency.unwrap(currency)][msg.sender] -= amount.toInt128();
            currency.transfer(to, amount);
        }
    }

    /// @inheritdoc IPoolManagerLight
    function settle() external payable onlyWhenUnlocked returns (uint256) {
        return _settle(msg.sender);
    }

    // if settling native, integrators should still call `sync` first to avoid DoS attack vectors
    function _settle(address recipient) internal returns (uint256 paid) {
        address currency = _synchedCurrency;

        // if not previously synced, or the syncedCurrency slot has been reset, expects native currency to be settled
        if (currency == address(0x0)) {
            paid = msg.value;
        } else {
            if (msg.value > 0) revert();
            // Reserves are guaranteed to be set because currency and reserves are always set together
            uint256 reservesBefore = _synchedReserves;
            uint256 reservesNow = Currency.wrap(currency).balanceOfSelf();
            paid = reservesNow - reservesBefore;
            _synchedCurrency = address(0x0);
        }

        _currencyDelta[currency][recipient] += paid.toInt128();
    }

    /// @inheritdoc IPoolManagerLight
    function sync(Currency currency) external {
        // address(0) is used for the native currency
        if (currency == Currency.wrap(address(0x0))) {
            // The reserves balance is not used for native settling, so we only need to reset the currency.
            _synchedCurrency = address(0x0);
        } else {
            uint256 balance = currency.balanceOfSelf();
            _synchedCurrency = Currency.unwrap(currency);
            _synchedReserves = balance;
        }
    }

    /// @inheritdoc IPoolManagerLight
    /// @dev Certora - to be summarized
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {}

    /// @inheritdoc IPoolManagerLight
    function swap(
        PoolKey memory key, 
        IPoolManager.SwapParams memory params, 
        bytes calldata hookData
    ) external onlyWhenUnlocked returns (BalanceDelta swapDelta) {
        if (params.amountSpecified == 0) revert("Zero amount");

        BeforeSwapDelta beforeSwapDelta;
        int256 amountToSwap;
        uint24 lpFeeOverride;
        (amountToSwap, beforeSwapDelta, lpFeeOverride) = Hooks.beforeSwap(key.hooks, key, params, hookData);

        swapDelta = BalanceDelta.wrap(_swap(amountToSwap));

        /// _accountPoolBalanceDelta
        _currencyDelta[Currency.unwrap(key.currency0)][msg.sender] += BalanceDeltaLibrary.amount0(swapDelta);
        _currencyDelta[Currency.unwrap(key.currency1)][msg.sender] += BalanceDeltaLibrary.amount1(swapDelta);
    }

    /// @dev Certora - summarize via CVL and assert that amountToSwap = 0;
    function _swap(int256 amountToSwap) internal view returns (int256 deltas) {
        deltas = amountToSwap;
    }
}