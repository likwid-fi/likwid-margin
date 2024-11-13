// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {CustomCurveBase} from "./libraries/CustomCurveBase.sol";
import {CurrencySettleTake} from "./libraries/CurrencySettleTake.sol";

contract MarginHook is CustomCurveBase {
    using CurrencySettleTake for Currency;

    error BalanceOverflow();

    event Sync(PoolId poolId, uint128 reserves0, uint128 reserves1);

    struct ReservesData {
        uint128 reserves0;
        uint128 reserves1;
    }

    mapping(PoolId => ReservesData) private _reservesData;

    constructor(IPoolManager _manager) CustomCurveBase(_manager) {}

    function getReserves(PoolId poolId) public view returns (uint128 _reserves0, uint128 _reserves1) {
        ReservesData storage _reserves = _reservesData[poolId];
        _reserves0 = _reserves.reserves0;
        _reserves1 = _reserves.reserves1;
    }

    function getAmountOutFromExactInput(uint256 amountIn, Currency input, Currency output, bool zeroForOne)
        internal
        pure
        override
        returns (uint256 amountOut)
    {
        // in constant-sum curve, tokens trade exactly 1:1
        amountOut = amountIn;
    }

    function getAmountInForExactOutput(uint256 amountOut, Currency input, Currency output, bool zeroForOne)
        internal
        pure
        override
        returns (uint256 amountIn)
    {
        // in constant-sum curve, tokens trade exactly 1:1
        amountIn = amountOut;
    }

    /// @notice Add liquidity through the hook
    /// @dev Not production-ready, only serves an example of hook-owned liquidity
    function addLiquidity(PoolKey calldata key, uint256 amount0, uint256 amount1) external {
        poolManager.unlock(
            abi.encodeCall(this.handleAddLiquidity, (key.currency0, key.currency1, amount0, amount1, msg.sender))
        );
    }

    /// @dev Handle liquidity addition by taking tokens from the sender and claiming ERC6909 to the hook address
    function handleAddLiquidity(
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address sender
    ) external selfOnly returns (bytes memory) {
        currency0.settle(poolManager, sender, amount0, false);
        currency0.take(poolManager, address(this), amount0, true);

        currency1.settle(poolManager, sender, amount1, false);
        currency1.take(poolManager, address(this), amount1, true);

        return abi.encode(amount0, amount1);
    }

    function _update(PoolId poolId, uint256 balance0, uint256 balance1) private {
        if (balance0 > type(uint128).max || balance1 > type(uint128).max) revert BalanceOverflow();
        ReservesData storage _reserves = _reservesData[poolId];
        _reserves.reserves0 = uint128(balance0);
        _reserves.reserves1 = uint128(balance1);
        emit Sync(poolId, _reserves.reserves0, _reserves.reserves1);
    }
}
