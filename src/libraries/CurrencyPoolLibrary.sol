// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Currency} from "likwid-v2-core/types/Currency.sol";
import {IPoolManager} from "likwid-v2-core/interfaces/IPoolManager.sol";
import {PoolKey} from "likwid-v2-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "likwid-v2-core/types/PoolId.sol";

import {CurrencyExtLibrary} from "./CurrencyExtLibrary.sol";

library CurrencyPoolLibrary {
    using PoolIdLibrary for PoolId;
    using SafeERC20 for IERC20;
    using CurrencyExtLibrary for Currency;

    error InsufficientValue();

    /// @notice Settle (pay) a currency to the PoolManager
    /// @param currency Currency to settle
    /// @param manager IPoolManager to settle to
    /// @param payer Address of the payer, the token sender
    /// @param amount Amount to send
    /// @param burn If true, burn the ERC-6909 token, otherwise ERC20-transfer to the PoolManager
    function settle(Currency currency, IPoolManager manager, address payer, uint256 amount, bool burn) internal {
        // for native currencies or burns, calling sync is not required
        // short circuit for ERC-6909 burns to support ERC-6909-wrapped native tokens
        if (burn) {
            manager.burn(payer, currency.toId(), amount);
        } else if (currency.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            IERC20 token = IERC20(Currency.unwrap(currency));
            if (payer != address(this)) {
                token.safeTransferFrom(payer, address(manager), amount);
            } else {
                token.safeTransfer(address(manager), amount);
            }
            manager.settle();
        }
    }

    /// @notice Take (receive) a currency from the PoolManager
    /// @param currency Currency to take
    /// @param manager IPoolManager to take from
    /// @param recipient Address of the recipient, the token receiver
    /// @param amount Amount to receive
    /// @param claims If true, mint the ERC-6909 token, otherwise ERC20-transfer from the PoolManager to recipient
    function take(Currency currency, IPoolManager manager, address recipient, uint256 amount, bool claims) internal {
        claims ? manager.mint(recipient, currency.toId(), amount) : manager.take(currency, recipient, amount);
    }

    function toTokenId(Currency currency, PoolId poolId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(currency, poolId)));
    }

    function toTokenId(Currency currency, PoolKey memory key) internal pure returns (uint256) {
        return toTokenId(currency, key.toId());
    }
}
