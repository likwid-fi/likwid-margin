// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BaseMarginPositionTest} from "../BaseMarginPosition.t.sol";

contract VeryLargeVsVerySmallTest is BaseMarginPositionTest {
    function _createTokens() internal virtual override returns (address tokenA, address tokenB) {
        tokenA = address(new MockERC20("TokenA", "TKA", 18));
        tokenB = address(new MockERC20("TokenB", "TKB", 6));
    }

    function _amount0ToAdd() internal virtual override returns (uint256) {
        return 1000e18;
    }

    function _amount1ToAdd() internal virtual override returns (uint256) {
        return 1e8;
    }
}
