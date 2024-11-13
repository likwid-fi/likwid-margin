// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC6909Claims} from "@uniswap/v4-core/src/ERC6909Claims.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";

contract MirrorTokenManager is IMirrorTokenManager, ERC6909Claims {
    using CurrencyLibrary for Currency;

    uint256 private _id = 0;

    mapping(Currency => mapping(PoolId => uint256)) private _poolTokenId;

    constructor(IMarginPositionManager _poolManager) {}

    function getTokenId(PoolId poolId, Currency currency) public returns (uint256 _tokenId) {
        _tokenId = _poolTokenId[currency][poolId];
        if (_tokenId == 0) {
            _tokenId = _id++;
            _poolTokenId[currency][poolId] = _tokenId;
        }
    }
}
