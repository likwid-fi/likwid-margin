// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

using InterestStatusLibrary for InterestStatus global;

struct InterestStatus {
    /// @notice The pair cumulative interest of the first currency in the pool.
    uint256 pairCumulativeInterest0;
    /// @notice The lending cumulative interest of the first currency in the pool.
    uint256 lendingCumulativeInterest0;
    /// @notice The pair cumulative interest of the second currency in the pool.
    uint256 pairCumulativeInterest1;
    /// @notice The lending cumulative interest of the second currency in the pool.
    uint256 lendingCumulativeInterest1;
}

library InterestStatusLibrary {
    function getLendingInterest(InterestStatus memory _status, uint256 totalInterest, bool isZero)
        internal
        pure
        returns (uint256 interest)
    {
        if (isZero) {
            interest = Math.mulDiv(
                totalInterest,
                _status.lendingCumulativeInterest0,
                _status.pairCumulativeInterest0 + _status.lendingCumulativeInterest0,
                Math.Rounding.Ceil
            );
        } else {
            interest = Math.mulDiv(
                totalInterest,
                _status.lendingCumulativeInterest1,
                _status.pairCumulativeInterest1 + _status.lendingCumulativeInterest1,
                Math.Rounding.Ceil
            );
        }
    }
}
