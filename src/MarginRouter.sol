// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CurrencySettleTake} from "./libraries/CurrencySettleTake.sol";

import {MarginHook} from "./MarginHook.sol";
import {Test, console2} from "forge-std/Test.sol";

contract MarginRouter is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;
    using Hooks for IHooks;

    IPoolManager public immutable poolManager;
    MarginHook public immutable hook;

    error InsufficientOutputReceived();

    constructor(IPoolManager _manager, MarginHook _hook) {
        hook = _hook;
        poolManager = _manager;
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "MarginRouter: EXPIRED");
        _;
    }

    function exactInput(address[] calldata path, address to, uint256 amountIn, uint256 amountOutMin, uint256 deadline)
        external
        payable
        ensure(deadline)
        returns (uint256 amountOut)
    {
        require(path.length == 2, "PATH_ERROR");
        amountOut = abi.decode(poolManager.unlock(abi.encode(path, to, amountIn, amountOutMin)), (uint256));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(poolManager));

        (address[] memory path, address to, uint256 amountIn, uint256 amountOutMin) =
            abi.decode(rawData, (address[], address, uint256, uint256));

        bool zeroForOne = path[0] < path[1];
        (Currency currency0, Currency currency1) = zeroForOne
            ? (Currency.wrap(path[0]), Currency.wrap(path[1]))
            : (Currency.wrap(path[1]), Currency.wrap(path[0]));

        PoolKey memory key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: hook});

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0});

        BalanceDelta delta = poolManager.swap(key, params, "");

        uint256 amountOut = uint256(int256(delta.amount1()));
        if (amountOut < amountOutMin) revert InsufficientOutputReceived();

        Currency.wrap(path[0]).settle(poolManager, address(this), amountIn, false);
        Currency.wrap(path[1]).take(poolManager, to, amountOut, false);
        return abi.encode(amountOut);
    }
}
