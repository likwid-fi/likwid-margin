// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

// Openzeppelin
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {IBasePositionManager} from "../interfaces/IBasePositionManager.sol";
import {SafeCallback} from "./SafeCallback.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {PoolId} from "../types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../types/Currency.sol";
import {IVault} from "../interfaces/IVault.sol";
import {CustomRevert} from "../libraries/CustomRevert.sol";
import {CurrencyPoolLibrary} from "../libraries/CurrencyPoolLibrary.sol";

abstract contract BasePositionManager is IBasePositionManager, SafeCallback, ERC721, Owned {
    using CurrencyPoolLibrary for Currency;
    using CustomRevert for bytes4;

    uint256 public nextId = 1;

    mapping(uint256 tokenId => PoolId poolId) public poolIds;
    mapping(PoolId poolId => PoolKey poolKey) public poolKeys;

    constructor(string memory name_, string memory symbol_, address initialOwner, IVault _vault)
        SafeCallback(_vault)
        Owned(initialOwner)
        ERC721(name_, symbol_)
    {}

    modifier ensure(uint256 deadline) {
        _ensure(deadline);
        _;
    }

    function _ensure(uint256 deadline) internal view {
        require(deadline == 0 || deadline >= block.timestamp, "EXPIRED");
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

    function _processDelta(
        address sender,
        address recipient,
        PoolKey memory key,
        BalanceDelta delta,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal returns (uint256 amount0, uint256 amount1) {
        amount0 = delta.amount0() < 0 ? uint256(-int256(delta.amount0())) : uint256(int256(delta.amount0()));
        if ((amount0Min > 0 && amount0 < amount0Min) || (amount0Max > 0 && amount0 > amount0Max)) {
            PriceSlippageTooHigh.selector.revertWith();
        }
        if (delta.amount0() < 0) {
            key.currency0.settle(vault, sender, amount0, false);
        } else if (delta.amount0() > 0) {
            key.currency0.take(vault, recipient, amount0, false);
        }

        amount1 = delta.amount1() < 0 ? uint256(-int256(delta.amount1())) : uint256(int256(delta.amount1()));
        if ((amount1Min > 0 && amount1 < amount1Min) || (amount1Max > 0 && amount1 > amount1Max)) {
            PriceSlippageTooHigh.selector.revertWith();
        }
        if (delta.amount1() < 0) {
            key.currency1.settle(vault, sender, amount1, false);
        } else if (delta.amount1() > 0) {
            key.currency1.take(vault, recipient, amount1, false);
        }

        _clearNative(sender);
    }

    function _mintPosition(PoolKey memory key, address to) internal returns (uint256 tokenId) {
        tokenId = nextId++;
        _mint(to, tokenId);

        PoolId poolId = key.toId();
        poolIds[tokenId] = poolId;
        if (poolKeys[poolId].currency1 == Currency.wrap(address(0))) {
            poolKeys[poolId] = key;
        } else {
            PoolKey memory existingKey = poolKeys[poolId];
            if (!(existingKey.currency0 == key.currency0 && existingKey.currency1 == key.currency1
                        && existingKey.fee == key.fee && existingKey.marginFee == key.marginFee)) {
                MismatchedPoolKey.selector.revertWith();
            }
        }
    }
}
