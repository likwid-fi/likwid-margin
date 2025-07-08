// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.19;

import {UQ112x112} from "./UQ112x112.sol";
import {PriceMath} from "./PriceMath.sol";

library TruncatedOracle {
    using UQ112x112 for uint224;
    using PriceMath for uint224;

    /// @notice Thrown when trying to interact with an Oracle of a non-initialized pool
    error OracleCardinalityCannotBeZero();

    /// @notice Thrown when trying to observe a price that is older than the oldest recorded price
    /// @param oldestTimestamp Timestamp of the oldest remaining observation
    /// @param targetTimestamp Invalid timestamp targeted to be observed
    error TargetPredatesOldestObservation(uint32 oldestTimestamp, uint32 targetTimestamp);

    /// @notice This is the max amount of millionth price1X112 in either direction that the pool is allowed to move at one time
    uint32 constant MAX_PRICE_SECOND_MOVE = 3000; // 0.3%/second

    struct Observation {
        // the block timestamp of the observation
        uint32 blockTimestamp;
        uint224 reserves;
        uint256 price1CumulativeLast;
    }

    function transform(Observation memory last, uint32 blockTimestamp, uint112 reserve0, uint112 reserve1)
        private
        pure
        returns (Observation memory)
    {
        unchecked {
            uint32 delta = blockTimestamp > last.blockTimestamp
                ? blockTimestamp - last.blockTimestamp
                : blockTimestamp + (type(uint32).max - last.blockTimestamp);
            uint224 price1X112 = PriceMath.getReserves(reserve0, reserve1).getPrice1X112();
            uint224 prevPrice1X112 = last.reserves.getPrice1X112();
            reserve0 = prevPrice1X112.truncated(reserve0, reserve1, MAX_PRICE_SECOND_MOVE * delta);
            uint224 reserves = PriceMath.getReserves(reserve0, reserve1);

            return Observation({
                blockTimestamp: blockTimestamp,
                reserves: reserves,
                price1CumulativeLast: last.price1CumulativeLast + price1X112 * delta
            });
        }
    }

    function initialize(Observation[65535] storage self, uint32 time, uint112 reserve0, uint112 reserve1)
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {
        uint224 reserves = PriceMath.getReserves(reserve0, reserve1);
        self[0] = Observation({blockTimestamp: time, reserves: reserves, price1CumulativeLast: 0});
        return (1, 1);
    }

    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        uint112 reserve0,
        uint112 reserve1,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        unchecked {
            Observation memory last = self[index];

            // early return if we've already written an observation this block
            if (last.blockTimestamp == blockTimestamp) return (index, cardinality);

            // if the conditions are right, we can bump the cardinality
            if (cardinalityNext > cardinality && index == (cardinality - 1)) {
                cardinalityUpdated = cardinalityNext;
            } else {
                cardinalityUpdated = cardinality;
            }
            indexUpdated = (index + 1) % cardinalityUpdated;
            if (reserve0 == 0 || reserve1 == 0) {
                delete self[indexUpdated];
            } else {
                self[indexUpdated] = transform(last, blockTimestamp, reserve0, reserve1);
            }
        }
    }

    /// @notice Prepares the oracle array to store up to `next` observations
    /// @param self The stored oracle array
    /// @param current The current next cardinality of the oracle array
    /// @param next The proposed next cardinality which will be populated in the oracle array
    /// @return next The next cardinality which will be populated in the oracle array
    function grow(Observation[65535] storage self, uint16 current, uint16 next) internal returns (uint16) {
        unchecked {
            if (current == 0) revert OracleCardinalityCannotBeZero();
            // no-op if the passed next value isn't greater than the current next value
            if (next <= current) return current;
            // store in each slot to prevent fresh SSTOREs in swaps
            // this data will not be used because the reserves is still zero
            for (uint16 i = current; i < next; i++) {
                self[i].blockTimestamp = 1;
            }
            return next;
        }
    }

    /// @notice comparator for 32-bit timestamps
    /// @dev safe for 0 or 1 overflows, a and b _must_ be chronologically before or equal to time
    /// @param time A timestamp truncated to 32 bits
    /// @param a A comparison timestamp from which to determine the relative position of `time`
    /// @param b From which to determine the relative position of `time`
    /// @return Whether `a` is chronologically <= `b`
    function lte(uint32 time, uint32 a, uint32 b) private pure returns (bool) {
        unchecked {
            // if there hasn't been overflow, no need to adjust
            if (a <= time && b <= time) return a <= b;

            uint256 aAdjusted = a > time ? a : a + 2 ** 32;
            uint256 bAdjusted = b > time ? b : b + 2 ** 32;

            return aAdjusted <= bAdjusted;
        }
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a target, i.e. where [beforeOrAt, atOrAfter] is satisfied.
    /// The result may be the same observation, or adjacent observations.
    /// @dev The answer must be contained in the array, used when the target is located within the stored observation
    /// boundaries: older than the most recent observation and younger, or the same age as, the oldest observation
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param target The timestamp at which the reserved observation should be for
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return beforeOrAt The observation recorded before, or at, the target
    /// @return atOrAfter The observation recorded at, or after, the target
    function binarySearch(Observation[65535] storage self, uint32 time, uint32 target, uint16 index, uint16 cardinality)
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        unchecked {
            uint256 l = (index + 1) % cardinality; // oldest observation
            uint256 r = l + cardinality - 1; // newest observation
            uint256 i;
            while (true) {
                i = (l + r) / 2;

                beforeOrAt = self[i % cardinality];

                // we've landed on an uninitialized tick, keep searching higher (more recently)
                if (beforeOrAt.reserves == 0) {
                    l = i + 1;
                    continue;
                }

                atOrAfter = self[(i + 1) % cardinality];

                bool targetAtOrAfter = lte(time, beforeOrAt.blockTimestamp, target);

                // check if we've found the answer!
                if (targetAtOrAfter && lte(time, target, atOrAfter.blockTimestamp)) break;

                if (!targetAtOrAfter) r = i - 1;
                else l = i + 1;
            }
        }
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a given target, i.e. where [beforeOrAt, atOrAfter] is satisfied
    /// @dev Assumes there is at least 1 initialized observation.
    /// Used by observeSingle() to compute the counterfactual accumulator values as of a given block timestamp.
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param target The timestamp at which the reserved observation should be for
    /// @param reserve0 reserve0
    /// @param reserve1 reserve1
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return beforeOrAt The observation which occurred at, or before, the given timestamp
    /// @return atOrAfter The observation which occurred at, or after, the given timestamp
    function getSurroundingObservations(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        uint112 reserve0,
        uint112 reserve1,
        uint16 index,
        uint16 cardinality
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        unchecked {
            // optimistically set before to the newest observation
            beforeOrAt = self[index];

            // if the target is chronologically at or after the newest observation, we can early return
            if (lte(time, beforeOrAt.blockTimestamp, target)) {
                if (beforeOrAt.blockTimestamp == target) {
                    // if newest observation equals target, we're in the same block, so we can ignore atOrAfter
                    return (beforeOrAt, atOrAfter);
                } else {
                    // otherwise, we need to transform
                    return (beforeOrAt, transform(beforeOrAt, target, reserve0, reserve1));
                }
            }

            // now, set before to the oldest observation
            beforeOrAt = self[(index + 1) % cardinality];
            if (beforeOrAt.reserves == 0) beforeOrAt = self[0];

            // ensure that the target is chronologically at or after the oldest observation
            if (!lte(time, beforeOrAt.blockTimestamp, target)) {
                revert TargetPredatesOldestObservation(beforeOrAt.blockTimestamp, target);
            }

            // if we've reached this point, we have to binary search
            return binarySearch(self, time, target, index, cardinality);
        }
    }

    /// @dev Reverts if an observation at or before the desired observation timestamp does not exist.
    /// 0 may be passed as `secondsAgo' to return the current cumulative values.
    /// If called with a timestamp falling between two observations, returns the counterfactual accumulator values
    /// at exactly the timestamp between the two observations.
    /// @param self The stored oracle array
    /// @param time The current block timestamp
    /// @param secondsAgo The amount of time to look back, in seconds, at which point to return an observation
    /// @param reserve0 reserve0
    /// @param reserve1 reserve1
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return reserves reserves
    /// @return price1CumulativeLast price1CumulativeLast, as of `secondsAgo`
    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        uint112 reserve0,
        uint112 reserve1,
        uint16 index,
        uint16 cardinality
    ) internal view returns (uint224 reserves, uint256 price1CumulativeLast) {
        unchecked {
            if (secondsAgo == 0) {
                Observation memory last = self[index];
                if (last.blockTimestamp != time) last = transform(last, time, reserve0, reserve1);
                return (last.reserves, last.price1CumulativeLast);
            }

            uint32 target = time - secondsAgo;

            (Observation memory beforeOrAt, Observation memory atOrAfter) =
                getSurroundingObservations(self, time, target, reserve0, reserve1, index, cardinality);

            if (target == beforeOrAt.blockTimestamp) {
                // we're at the left boundary
                return (beforeOrAt.reserves, beforeOrAt.price1CumulativeLast);
            } else if (target == atOrAfter.blockTimestamp) {
                // we're at the right boundary
                return (atOrAfter.reserves, atOrAfter.price1CumulativeLast);
            } else {
                // we're in the middle
                uint32 observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
                uint32 targetDelta = target - beforeOrAt.blockTimestamp;
                uint112 beforeReserve1 = beforeOrAt.reserves.getReserve1();
                uint112 afterReserve1 = atOrAfter.reserves.getReserve1();
                if (beforeReserve1 > afterReserve1) {
                    reserve1 = afterReserve1 + (beforeReserve1 - afterReserve1) * targetDelta / observationTimeDelta;
                } else {
                    reserve1 = beforeReserve1 + (afterReserve1 - beforeReserve1) * targetDelta / observationTimeDelta;
                }
                reserve0 = uint224(
                    uint256(reserve1) * (atOrAfter.price1CumulativeLast - beforeOrAt.price1CumulativeLast)
                        / observationTimeDelta
                ).decode();
                uint224 reserve = PriceMath.getReserves(reserve0, reserve1);
                return (reserve, beforeOrAt.price1CumulativeLast + reserve.getPrice1X112() * targetDelta);
            }
        }
    }

    /// @notice Returns the accumulator values as of each time seconds ago from the given time in the array of `secondsAgos`
    /// @dev Reverts if `secondsAgos` > oldest observation
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param secondsAgos Each amount of time to look back, in seconds, at which point to return an observation
    /// @param reserve0 reserve0
    /// @param reserve1 reserve1
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return reserves reserves, as of each `secondsAgo`
    /// @return price1CumulativeLast price1CumulativeLast, as of each `secondsAgo`
    function observe(
        Observation[65535] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        uint112 reserve0,
        uint112 reserve1,
        uint16 index,
        uint16 cardinality
    ) internal view returns (uint224[] memory reserves, uint256[] memory price1CumulativeLast) {
        unchecked {
            if (cardinality == 0) revert OracleCardinalityCannotBeZero();

            reserves = new uint224[](secondsAgos.length);
            price1CumulativeLast = new uint256[](secondsAgos.length);
            for (uint256 i = 0; i < secondsAgos.length; i++) {
                (reserves[i], price1CumulativeLast[i]) =
                    observeSingle(self, time, secondsAgos[i], reserve0, reserve1, index, cardinality);
            }
        }
    }
}
