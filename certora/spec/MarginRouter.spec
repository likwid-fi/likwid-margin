import "./CVLERC20.spec";
import "./MathSummary.spec";
import "./PoolManager.spec";

using MarginHookManager as Hook;

methods {
    /// Unresolved unlock callback:
    function _.unlockCallback(bytes) external => DISPATCHER(true);

    /// Unresolved unlock callback in PM:
    unresolved external in PoolManager.unlock(bytes) => DISPATCH [
        MarginHookManager.unlockCallback(bytes),
        MarginRouter.unlockCallback(bytes)
    ] default HAVOC_ECF;
    /// Unresolved unlock callbacks:
    unresolved external in MarginHookManager.unlockCallback(bytes) => DISPATCH [
        MarginHookManager.handleRelease(MarginHookManager.ReleaseParams),
        MarginHookManager.handleAddLiquidity(address,PoolManager.PoolKey,uint256,uint256),
        MarginHookManager.handleMargin(address,MarginHookManager.MarginParams)
    ] default HAVOC_ECF;
    
    unresolved external in MarginRouter.unlockCallback(bytes) => DISPATCH [
        MarginRouter.handelSwap(address,MarginRouter.SwapParams)
    ] default HAVOC_ECF;

    /// This one is intended to solve the unresolution of the hook call to `beforeSwap` from within PoolManager.swap()
    unresolved external in Hooks.callHook(address,bytes) => DISPATCH [
        MarginHookManager.beforeSwap(address,PoolManager.PoolKey,IPoolManager.SwapParams,bytes)
    ] default HAVOC_ECF;

    /// Pure function is summarized by a generic arbitratry mapping - this is logically sound.
    function Hooks.hasPermission(address self, uint160 flag) internal returns (bool) => CVLHasPermission(self, flag);
}

definition BEFORE_SWAP_FLAG() returns uint160 = 1 << 7;
definition AFTER_SWAP_FLAG() returns uint160 = 1 << 6;
definition BEFORE_SWAP_RETURNS_DELTA_FLAG() returns uint160 = 1 << 3;
definition AFTER_SWAP_RETURNS_DELTA_FLAG() returns uint160 = 1 << 2;
definition BEFORE_ADD_LIQUIDITY_FLAG() returns uint160 = 1 << 11;

persistent ghost CVLHasPermission(address,uint160) returns bool {
    /// Fix the permissions based on the MarginHookManager.
    axiom CVLHasPermission(Hook, BEFORE_SWAP_FLAG()) == true;
    axiom CVLHasPermission(Hook, BEFORE_SWAP_RETURNS_DELTA_FLAG()) == true;
    axiom CVLHasPermission(Hook, AFTER_SWAP_FLAG()) == false;
    axiom CVLHasPermission(Hook, AFTER_SWAP_RETURNS_DELTA_FLAG()) == false;
    axiom CVLHasPermission(Hook, BEFORE_ADD_LIQUIDITY_FLAG()) == true;
}

use builtin rule sanity filtered{f -> f.contract == currentContract}

/// For a non-zero amountIn, the amount out should also be non-zero.
/// Inner-assert: the call to swap() should not involve any non-zero amount to be swapped within PoolManager. 
rule swapCorrectness() {
    env e;
    MarginRouter.SwapParams params;
    MarginHookManager.HookStatus status = Hook.getStatus(e, params.poolId);
    /// Prove this is correct.
    require status.key.hooks == Hook;
    uint256 amountOut = exactInput(e, params);

    assert params.amountIn > 0 => amountOut > 0;
}