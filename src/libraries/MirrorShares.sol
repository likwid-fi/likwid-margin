// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.0;

import {PoolId} from "../types/PoolId.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {Math} from "./Math.sol";

/// @title MirrorShares
/// @notice Claims on a pool's lendReserves handed out by the mirror part of a swapMirror, held as vault ERC6909
/// balances. A share is worth `depositCumulativeLast / Q96` of the currency, so it accrues interest the same way
/// margin collateral does.
library MirrorShares {
    /// @notice The ERC6909 id of the shares for one currency of a pool
    /// @dev The top bit is set, so the id can never equal a currency claim id (a uint160)
    function toId(PoolId poolId, bool forOne) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, forOne))) | (1 << 255);
    }

    /// @notice The shares an amount is worth at the given deposit cumulative, rounded down
    function toShares(uint256 amount, uint256 depositCumulativeLast) internal pure returns (uint256) {
        return Math.mulDiv(amount, FixedPoint96.Q96, depositCumulativeLast);
    }

    /// @notice The amount shares are worth at the given deposit cumulative, rounded down
    function toAmount(uint256 shares, uint256 depositCumulativeLast) internal pure returns (uint256) {
        return Math.mulDiv(shares, depositCumulativeLast, FixedPoint96.Q96);
    }
}
