// SPDX-License-Identifier: MIT
// Likwid Contracts
pragma solidity ^0.8.26;

import {PoolId} from "likwid-v2-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "likwid-v2-core/types/Currency.sol";

abstract contract BaseFees {
    event Fees(PoolId indexed poolId, Currency indexed currency, address indexed sender, uint8 feeType, uint256 fee);

    enum FeeType {
        SWAP,
        MARGIN,
        INTERESTS
    }
}
