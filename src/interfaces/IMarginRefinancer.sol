// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "../types/PoolKey.sol";

/// @title IMarginRefinancer
/// @notice A contract that accepts margin positions transferred to it for refinancing —
/// e.g. taking over the position's floating-rate pool debt against a fixed-rate loan.
interface IMarginRefinancer {
    /// @notice Called before the position is transferred, to let the refinancer choose (and arm)
    /// the destination salt in its own namespace. Arming lets the refinancer's
    /// onMarginPositionReceived hook reject any transfer it did not authorize, which prevents an
    /// attacker from pre-occupying a predictable destination slot to block the refinance.
    /// @param key The pool key of the position
    /// @param tokenId The wrapper tokenId being refinanced
    /// @param data Refinancer-specific parameters chosen by the borrower
    /// @return salt The destination salt the caller must transfer the position to
    function prepareRefinance(PoolKey calldata key, uint256 tokenId, bytes calldata data)
        external
        returns (bytes32 salt);

    /// @notice Called right after a position has been transferred to this contract.
    /// @dev Must revert if the refinancing cannot be completed, undoing the transfer atomically.
    /// @param key The pool key of the position
    /// @param salt The position salt under this contract's ownership in the margin core
    /// @param borrower The account entitled to the position (repays the loan, reclaims collateral)
    /// @param data Refinancer-specific parameters chosen by the borrower (terms, quote id, ...)
    function onRefinance(PoolKey calldata key, bytes32 salt, address borrower, bytes calldata data) external;
}
