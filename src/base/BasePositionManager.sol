// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

// Openzeppelin
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {ImmutableState} from "./ImmutableState.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../types/Currency.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IUnlockCallback} from "../interfaces/callback/IUnlockCallback.sol";
import {CustomRevert} from "../libraries/CustomRevert.sol";
import {CurrencyPoolLibrary} from "../libraries/CurrencyPoolLibrary.sol";

abstract contract BasePositionManager is ImmutableState, IUnlockCallback, ERC721, Owned, ReentrancyGuardTransient {
    using CurrencyPoolLibrary for Currency;
    using CustomRevert for bytes4;

    error NotOwner();

    error InvalidCallback();

    uint256 public nextId = 1;

    mapping(uint256 tokenId => PoolId poolId) public poolIds;
    mapping(PoolId poolId => PoolKey poolKey) public poolKeys;

    constructor(string memory name_, string memory symbol_, address initialOwner, IVault _vault)
        ImmutableState(_vault)
        Owned(initialOwner)
        ERC721(name_, symbol_)
    {}

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    function _requireAuth(address spender, uint256 tokenId) internal view {
        if (spender != ownerOf(tokenId)) {
            NotOwner.selector.revertWith();
        }
    }

    function _clearNative(address spender) internal {
        // clear any native currency left in the contract
        uint256 balance = address(this).balance;
        if (balance > 0) {
            CurrencyLibrary.ADDRESS_ZERO.transfer(spender, balance);
        }
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external virtual returns (bytes memory);
}
