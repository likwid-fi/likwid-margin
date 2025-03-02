// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";

struct LiquidateStatus {
    Currency marginCurrency;
    Currency borrowCurrency;
    uint256 oracleReserves;
    uint256 statusReserves;
}
