// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library LiquidityLevel {
    uint256 constant LP_FLAG = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0;

    uint8 constant NO_MARGIN = 1;
    uint8 constant ONE_MARGIN = 2;
    uint8 constant ZERO_MARGIN = 3;
    uint8 constant BOTH_MARGIN = 4;

    error LevelError();

    function validate(uint8 level) internal pure returns (bool valid) {
        valid = level >= NO_MARGIN && level <= BOTH_MARGIN;
        if (!valid) revert LevelError();
    }

    function zeroForMargin(uint8 level) internal pure returns (bool value) {
        value = level == ZERO_MARGIN || level == BOTH_MARGIN;
    }

    function oneForMargin(uint8 level) internal pure returns (bool value) {
        value = level == ONE_MARGIN || level == BOTH_MARGIN;
    }

    function getLevelId(uint8 level, uint256 id) internal pure returns (uint256 levelId) {
        if (validate(level)) {
            levelId = (id & LP_FLAG) + level;
        }
    }
}
