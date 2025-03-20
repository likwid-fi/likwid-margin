// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// V4 core
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {CurrencyPoolLibrary} from "./libraries/CurrencyPoolLibrary.sol";

contract MarginHook is BaseHook, Owned {
    using SafeCast for uint256;
    using CurrencyPoolLibrary for Currency;

    error InvalidInitialization();

    IPairPoolManager public immutable pairPoolManager;

    constructor(address initialOwner, IPoolManager _manager, IPairPoolManager _pairPoolManager)
        Owned(initialOwner)
        BaseHook(_manager)
    {
        pairPoolManager = _pairPoolManager;
    }

    modifier updatePoolStatus(PoolKey calldata key) {
        pairPoolManager.statusManager().setBalances(key);
        _;
        pairPoolManager.statusManager().updateBalances(key);
    }

    // ******************** HOOK FUNCTIONS ********************

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (address(key.hooks) != address(this)) revert InvalidInitialization();
        pairPoolManager.initialize(key);
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Facilitate a custom curve via beforeSwap + return delta
    /// @dev input tokens are taken from the PoolManager, creating a debt paid by the swapper
    /// @dev output tokens are transferred from the hook to the PoolManager, creating a credit claimed by the swapper
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        updatePoolStatus(key)
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (Currency specified, Currency unspecified, uint256 specifiedAmount, uint256 unspecifiedAmount, uint24 swapFee) =
            pairPoolManager.swap(sender, key, params);

        bool exactInput = params.amountSpecified < 0;
        BeforeSwapDelta returnDelta;
        if (exactInput) {
            // in exact-input swaps, the specified token is a debt that gets paid down by the swapper
            // the unspecified token is credited to the PoolManager, that is claimed by the swapper
            specified.take(poolManager, address(pairPoolManager), specifiedAmount, true);
            unspecified.settle(poolManager, address(pairPoolManager), unspecifiedAmount, true);
            //unspecified.settle(poolManager, address(this), unspecifiedAmount, true);
            returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount.toInt128());
        } else {
            // exactOutput
            // in exact-output swaps, the unspecified token is a debt that gets paid down by the swapper
            // the specified token is credited to the PoolManager, that is claimed by the swapper
            unspecified.take(poolManager, address(pairPoolManager), unspecifiedAmount, true);
            specified.settle(poolManager, address(pairPoolManager), specifiedAmount, true);
            //specified.settle(poolManager, address(this), specifiedAmount, true);
            returnDelta = toBeforeSwapDelta(-specifiedAmount.toInt128(), unspecifiedAmount.toInt128());
        }
        return (BaseHook.beforeSwap.selector, returnDelta, swapFee);
    }

    /// @notice No liquidity will be managed by v4 PoolManager
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert("No v4 Liquidity allowed");
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true, // -- disable v4 liquidity with a revert -- //
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // -- Custom Curve Handler --  //
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // -- Enables Custom Curves --  //
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
