// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

library TimeUtils {
    function getTimeElapsedMillisecond(uint32 blockTimestampLast)
        internal
        view
        returns (uint32 blockTS, uint256 timeElapsed)
    {
        blockTS = uint32(block.timestamp % 2 ** 32);
        if (blockTimestampLast <= blockTS) {
            timeElapsed = (blockTS - blockTimestampLast) * 10 ** 3; // MILLION=>BILLON
        } else {
            timeElapsed = (2 ** 32 - blockTimestampLast + blockTS) * 10 ** 3;
        }
    }
}
