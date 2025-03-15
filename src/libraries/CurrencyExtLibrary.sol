// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Currency} from "v4-core/types/Currency.sol";

import {IERC20} from "../external/openzeppelin-contracts/IERC20.sol";
import {SafeERC20} from "../external/openzeppelin-contracts/SafeERC20.sol";

library CurrencyExtLibrary {
    using SafeERC20 for IERC20;

    error InsufficientValue();

    function approve(Currency currency, address spender, uint256 amount) internal returns (bool success) {
        if (!currency.isAddressZero()) {
            IERC20 token = IERC20(Currency.unwrap(currency));
            token.forceApprove(spender, amount);
        }
        success = true;
    }

    function checkAmount(Currency currency, uint256 amount) internal returns (uint256 sendValue) {
        if (currency.isAddressZero()) {
            if (msg.value < amount) revert InsufficientValue();
            sendValue = amount < msg.value ? amount : msg.value;
        }
    }

    function transfer(Currency currency, address payer, address recipient, uint256 amount)
        internal
        returns (bool success)
    {
        if (currency.isAddressZero()) {
            (success,) = recipient.call{value: amount}("");
        } else {
            IERC20 token = IERC20(Currency.unwrap(currency));
            if (payer != address(this)) {
                token.safeTransferFrom(payer, recipient, amount);
            } else {
                token.safeTransfer(recipient, amount);
            }
            success = true;
        }
    }
}
