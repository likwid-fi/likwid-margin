// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeCallback} from "lib/v4-periphery/src/base/SafeCallback.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {IMarginHookManager} from "src/interfaces/IMarginHookManager.sol";
import {PoolId} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {IUnlockCallback} from "lib/v4-periphery/lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";

contract MarginRouter is SafeCallback {
    IMarginHookManager public immutable hook;

    address __sender;
    PoolId __poolId;

    constructor(address initialOwner, IPoolManager _manager, IMarginHookManager _hook)
        SafeCallback(_manager)
    {
        hook = _hook;
        poolManager = _manager;
    }

    modifier selfOnly() {
        if (msg.sender != address(this)) revert ("NotSelf");
        _;
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert ("LockFailure");
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
        returns (uint256 amountOut)
    {
        require(params.amountIn > 0, "AMOUNT_ERROR");
        amountOut = abi.decode(poolManager.unlock(abi.encodeCall(this.handelSwap, (msg.sender, params))), (uint256));
    }

    function handelSwap(address sender, SwapParams calldata params) external selfOnly returns (uint256) {
        __sender = sender;
        __poolId = params.poolId;
        return 0;
    }

    function getSender() external view returns (address) {return __sender;}
    function getPoolId() external view returns (PoolId) {return __poolId;}
}

contract PoolManager {
    bool private __unlocked;

    /// @notice This will revert if the contract is locked
    modifier onlyWhenUnlocked() {
        if (!__unlocked) revert("Is locked");
        _;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (__unlocked) revert("Still unlocked");
        __unlocked = true;

        // the caller does everything in this callback, including paying what they owe via calls to settle
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        __unlocked = false;
    }
}