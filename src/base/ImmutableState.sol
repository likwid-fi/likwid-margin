// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVault} from "../interfaces/IVault.sol";
import {IImmutableState} from "../interfaces/IImmutableState.sol";

/// @title Immutable State
/// @notice A collection of immutable state variables, commonly used across multiple contracts
contract ImmutableState is IImmutableState {
    /// @inheritdoc IImmutableState
    IVault public immutable vault;

    /// @notice Only allow calls from the LikwidVault contract
    modifier onlyVault() {
        _onlyVault();
        _;
    }

    function _onlyVault() internal view {
        if (msg.sender != address(vault)) revert NotVault();
    }

    constructor(IVault _vault) {
        vault = _vault;
    }
}
