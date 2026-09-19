// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.0;

/// @title PositionLibrary
/// @notice A library for creating unique identifiers for positions.
library PositionLibrary {
    /// @notice Calculates a unique position key for an owner and a salt.
    /// @param owner The owner of the position.
    /// @param salt A unique salt for the position.
    /// @return positionKey The unique identifier for the position.
    function calculatePositionKey(address owner, bytes32 salt) internal pure returns (bytes32 positionKey) {
        // This assembly block is a gas-optimized version of:
        // positionKey = keccak256(abi.encodePacked(owner, salt));
        assembly ("memory-safe") {
            // Use the scratch space (0x00-0x3f) to store the arguments to hash.
            mstore(0x00, owner)
            mstore(0x20, salt)
            // Hash the 20 bytes of owner and 32 bytes of salt.
            // An address is 20 bytes, but stored in a 32-byte word. It's right-aligned,
            // so we skip the first 12(0x0c) zero bytes.
            // The total length to hash is 20 (owner) + 32 (salt) = 52 bytes (0x34).
            positionKey := keccak256(0x0c, 0x34)
        }
    }
}
