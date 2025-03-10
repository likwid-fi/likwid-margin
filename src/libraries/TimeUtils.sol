// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

library TimeUtils {
    function getTimeElapsed(uint32 blockTimestampLast) internal view returns (uint256 timeElapsed) {
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        if (blockTimestampLast <= blockTS) {
            timeElapsed = uint256(blockTS - blockTimestampLast);
        } else {
            timeElapsed = uint256(2 ** 32 - blockTimestampLast + blockTS);
        }
    }

    function getTimeElapsedMicrosecond(uint32 blockTimestampLast) internal view returns (uint256 timeElapsed) {
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        if (blockTimestampLast <= blockTS) {
            timeElapsed = uint256(blockTS - blockTimestampLast) * 10 ** 6;
        } else {
            timeElapsed = uint256(2 ** 32 - blockTimestampLast + blockTS) * 10 ** 6;
        }
    }
}
