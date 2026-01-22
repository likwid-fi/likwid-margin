// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LikwidUSDT is ERC20 {
    constructor() ERC20("USDT", "USDT") {
        _mint(0x79347d7207C5c99445E6E386f1CCcbB31bfe3b1B, 1_000_000_000 * 10 ** decimals());
    }
}
