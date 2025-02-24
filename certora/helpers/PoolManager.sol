// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IUnlockCallback } from "lib/v4-periphery/lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { SafeCast } from "lib/v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import { BalanceDelta } from "lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol"; 
import { ERC6909Claims } from "lib/v4-periphery/lib/v4-core/src/ERC6909Claims.sol";
import { PoolKey } from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";

interface IPoolManager {
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
}

contract PoolManager is IPoolManager, ERC6909Claims {
    using SafeCast for uint256;

    bool private __unlocked;

    mapping(uint256 /* currency ID */ => mapping(address /* account */ => int128)) private _currencyDelta;

    /// @notice This will revert if the contract is locked
    modifier onlyWhenUnlocked() {
        if (!__unlocked) revert("Is locked");
        _;
    }

    /// @inheritdoc IPoolManager
    function unlock(bytes calldata data) external override returns (bytes memory result) {
        if (__unlocked) revert("Still unlocked");
        __unlocked = true;

        // the caller does everything in this callback, including paying what they owe via calls to settle
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        __unlocked = false;
    }

    /// @inheritdoc IPoolManager
    function burn(address from, uint256 id, uint256 amount) external onlyWhenUnlocked {
        _currencyDelta[id][msg.sender] += amount.toInt128();
        _burnFrom(from, id, amount);
    }

    /// @inheritdoc IPoolManager
    /// @dev Certora - to be summarized
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {}
}