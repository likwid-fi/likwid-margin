// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {CurrencyUtils} from "./libraries/CurrencyUtils.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {HookStatus} from "./types/HookStatus.sol";
import {IMarginHookManager} from "./interfaces/IMarginHookManager.sol";

contract MarginRouter is SafeCallback, Owned {
    using CurrencyLibrary for Currency;
    using CurrencyUtils for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    error LockFailure();
    error NotSelf();
    error InsufficientOutputReceived();

    event Swap(PoolId indexed poolId, address indexed sender, uint256 amount0, uint256 amount1, uint24 fee);

    IMarginHookManager public immutable hook;

    constructor(address initialOwner, IPoolManager _manager, IMarginHookManager _hook)
        Owned(initialOwner)
        SafeCallback(_manager)
    {
        hook = _hook;
        poolManager = _manager;
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    function _unlockCallback(bytes calldata data) internal virtual override returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert LockFailure();
        // if the call failed, bubble up the reason
        assembly ("memory-safe") {
            revert(add(returnData, 32), mload(returnData))
        }
    }

    struct SwapParams {
        PoolId poolId;
        bool zeroForOne;
        address to;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 amountOut;
        uint256 deadline;
    }

    function exactInput(SwapParams calldata params)
        external
        payable
        ensure(params.deadline)
        returns (uint256 amountOut)
    {
        require(params.amountIn > 0, "AMOUNT_ERROR");
        amountOut = abi.decode(poolManager.unlock(abi.encodeCall(this.handelSwap, (msg.sender, params))), (uint256));
    }

    function exactOutput(SwapParams calldata params)
        external
        payable
        ensure(params.deadline)
        returns (uint256 amountIn)
    {
        require(params.amountOut > 0 && params.amountIn == 0, "AMOUNT_ERROR");
        amountIn = abi.decode(poolManager.unlock(abi.encodeCall(this.handelSwap, (msg.sender, params))), (uint256));
    }

    function handelSwap(address sender, SwapParams calldata params) external selfOnly returns (uint256) {
        HookStatus memory _status = hook.getStatus(params.poolId);
        PoolKey memory key = _status.key;
        int256 amountSpecified;
        if (params.amountIn > 0) {
            amountSpecified = -int256(params.amountIn);
        } else if (params.amountOut > 0) {
            amountSpecified = int256(params.amountOut);
        }
        (Currency inputCurrency, Currency outputCurrency) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        if (amountSpecified != 0) {
            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: 0
            });
            uint256 amountIn;
            uint256 amountOut;
            BalanceDelta delta = poolManager.swap(key, swapParams, "");
            if (params.amountIn > 0) {
                amountOut = params.zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
                if (amountOut < params.amountOutMin) revert InsufficientOutputReceived();
                inputCurrency.settle(poolManager, sender, params.amountIn, false);
                outputCurrency.take(poolManager, params.to, amountOut, false);
                amountIn = params.amountIn;
                (uint256 amount0, uint256 amount1) = params.zeroForOne ? (amountIn, amountOut) : (amountOut, amountIn);
                emit Swap(key.toId(), sender, amount0, amount1, key.fee);
                return amountOut;
            } else if (params.amountOut > 0) {
                amountIn = params.zeroForOne ? uint256(-int256(delta.amount0())) : uint256(-int256(delta.amount1()));
                inputCurrency.settle(poolManager, sender, amountIn, false);
                outputCurrency.take(poolManager, params.to, params.amountOut, false);
                amountOut = params.amountOut;
                (uint256 amount0, uint256 amount1) = params.zeroForOne ? (amountOut, amountIn) : (amountIn, amountOut);
                emit Swap(key.toId(), sender, amount0, amount1, key.fee);
                return amountIn;
            }
        }
        return 0;
    }

    function withdrawFee(address token, address to, uint256 amount) external onlyOwner returns (bool success) {
        success = Currency.wrap(token).transfer(to, address(this), amount);
    }

    receive() external payable {}
}
