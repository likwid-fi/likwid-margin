// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CurrencySettleTake} from "./libraries/CurrencySettleTake.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

import {IMarginHook} from "./interfaces/IMarginHook.sol";
import {IMarginHookFactory} from "./interfaces/IMarginHookFactory.sol";

contract MarginRouter is SafeCallback, Owned {
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;

    error LockFailure();
    error NotSelf();

    IMarginHookFactory public immutable factory;

    error InsufficientOutputReceived();

    constructor(address initialOwner, IPoolManager _manager, IMarginHookFactory _factory)
        Owned(initialOwner)
        SafeCallback(_manager)
    {
        factory = _factory;
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
        address[] path;
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
        require(params.path.length == 2, "PATH_ERROR");
        require(params.amountIn > 0, "AMOUNTIN_ERROR");
        amountOut = abi.decode(poolManager.unlock(abi.encodeCall(this.handelSwap, (params))), (uint256));
    }

    function exactOutput(SwapParams calldata params)
        external
        payable
        ensure(params.deadline)
        returns (uint256 amountIn)
    {
        require(params.path.length == 2, "PATH_ERROR");
        require(params.amountOut > 0, "AMOUNTOUT_ERROR");
        amountIn = abi.decode(poolManager.unlock(abi.encodeCall(this.handelSwap, (params))), (uint256));
    }

    function handelSwap(SwapParams calldata params) external selfOnly returns (uint256) {
        bool zeroForOne = params.path[0] < params.path[1];
        (Currency currency0, Currency currency1) = zeroForOne
            ? (Currency.wrap(params.path[0]), Currency.wrap(params.path[1]))
            : (Currency.wrap(params.path[1]), Currency.wrap(params.path[0]));

        address hook = factory.getHookPair(params.path[0], params.path[1]);
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: IHooks(hook)});
        int256 amountSpecified;
        if (params.amountIn > 0) {
            amountSpecified = -int256(params.amountIn);
        } else if (params.amountOut > 0) {
            amountSpecified = int256(params.amountOut);
        }
        if (amountSpecified != 0) {
            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: 0
            });

            BalanceDelta delta = poolManager.swap(key, swapParams, "");
            if (params.amountIn > 0) {
                uint256 amountOut = uint256(int256(delta.amount1()));
                if (amountOut < params.amountOutMin) revert InsufficientOutputReceived();

                Currency.wrap(params.path[0]).settle(poolManager, address(this), params.amountIn, false);
                Currency.wrap(params.path[1]).take(poolManager, params.to, amountOut, false);
                return amountOut;
            } else if (params.amountOut > 0) {
                uint256 amountIn = uint256(int256(delta.amount1()));
                Currency.wrap(params.path[0]).settle(poolManager, address(this), amountIn, false);
                Currency.wrap(params.path[1]).take(poolManager, params.to, params.amountOut, false);
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
