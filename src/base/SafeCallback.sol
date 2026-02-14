// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUnlockCallback} from "../interfaces/callback/IUnlockCallback.sol";
import {IVault} from "../interfaces/IVault.sol";
import {ImmutableState} from "./ImmutableState.sol";

/// @title Safe Callback
/// @notice A contract that only allows the Likwid v2 Vault to call the unlockCallback
abstract contract SafeCallback is ImmutableState, IUnlockCallback {
    constructor(IVault _vault) ImmutableState(_vault) {}

    /// @inheritdoc IUnlockCallback
    /// @dev We force the onlyVault modifier by exposing a virtual function after the onlyVault check.
    function unlockCallback(bytes calldata data) external onlyVault returns (bytes memory) {
        return _unlockCallback(data);
    }

    /// @dev to be implemented by the child contract, to safely guarantee the logic is only executed by the Vault
    function _unlockCallback(bytes calldata data) internal virtual returns (bytes memory);
}
