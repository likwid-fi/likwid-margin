// SPDX-License-Identifier: MIT
// Likwid Contracts
pragma solidity ^0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Currency} from "likwid-v2-core/types/Currency.sol";

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
            sendValue = amount;
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
