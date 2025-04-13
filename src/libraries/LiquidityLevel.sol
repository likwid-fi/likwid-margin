// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library LiquidityLevel {
    uint256 constant LP_FLAG = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0;

    uint8 constant RETAIN_BOTH = 1;
    uint8 constant BORROW_TOKEN0 = 2;
    uint8 constant BORROW_TOKEN1 = 3;
    uint8 constant BORROW_BOTH = 4;

    error LevelError();

    function validate(uint8 level) internal pure returns (bool valid) {
        valid = level >= RETAIN_BOTH && level <= BORROW_BOTH;
        if (!valid) revert LevelError();
    }

    function zeroForMargin(uint8 level) internal pure returns (bool value) {
        value = level == BORROW_TOKEN1 || level == BORROW_BOTH;
    }

    function oneForMargin(uint8 level) internal pure returns (bool value) {
        value = level == BORROW_TOKEN0 || level == BORROW_BOTH;
    }

    function getPoolId(uint256 id) internal pure returns (uint256 poolId) {
        poolId = id & LP_FLAG;
    }

    function getLevelId(uint8 level, uint256 id) internal pure returns (uint256 levelId) {
        if (validate(level)) {
            levelId = (id & LP_FLAG) + level;
        }
    }
}
