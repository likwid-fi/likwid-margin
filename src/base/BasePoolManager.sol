// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// V4 core
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";

abstract contract BasePoolManager is SafeCallback, Owned {
    error NotSelf();
    error LockFailure();

    /// @dev Only this address may call this function
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    constructor(address initialOwner, IPoolManager _poolManager) Owned(initialOwner) SafeCallback(_poolManager) {}

    function _unlockCallback(bytes calldata data) internal virtual override returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert LockFailure();
        // if the call failed, bubble up the reason
        assembly ("memory-safe") {
            revert(add(returnData, 32), mload(returnData))
        }
    }
}
