// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

library CurrencyUtils {
    using CurrencyLibrary for Currency;

    function safeApprove(Currency currency, address spender, uint256 value) internal returns (bool) {
        (bool success, bytes memory data) =
            Currency.unwrap(currency).call(abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, value));
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }

    function safeTransfer(Currency currency, address to, uint256 amount) internal returns (bool) {
        (bool success, bytes memory data) =
            Currency.unwrap(currency).call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }

    function safeTransferFrom(Currency currency, address from, address to, uint256 amount) internal returns (bool) {
        (bool success, bytes memory data) = Currency.unwrap(currency).call(
            abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount)
        );
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }

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
            bool success;
            if (payer != address(this)) {
                success = safeTransferFrom(currency, payer, address(manager), amount);
            } else {
                success = safeTransfer(currency, address(manager), amount);
            }
            require(success, "settle:transfer did not succeed");
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

    function approve(Currency currency, address spender, uint256 amount) internal returns (bool success) {
        if (!currency.isAddressZero()) {
            success = safeApprove(currency, spender, amount);
        } else {
            success = true;
        }
    }

    function transfer(Currency currency, address payer, address recipient, uint256 amount)
        internal
        returns (bool success)
    {
        if (currency.isAddressZero()) {
            (success,) = recipient.call{value: amount}("");
        } else {
            if (payer != address(this)) {
                success = safeTransferFrom(currency, payer, recipient, amount);
            } else {
                success = safeTransfer(currency, recipient, amount);
            }
        }
    }

    function toKeyId(Currency currency, PoolKey memory key) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(currency, key)));
    }
}
