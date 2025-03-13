// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

abstract contract BaseFees {
    event Fees(PoolId indexed poolId, Currency indexed currency, address indexed sender, uint8 feeType, uint256 fee);

    enum FeeType {
        SWAP,
        MARGIN,
        INTERESTS
    }
}
