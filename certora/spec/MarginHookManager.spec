import "./CVLERC20.spec";
import "./MathSummary.spec";
import "./PoolManager.spec";

methods {
    /// Unresolved unlock callback:
    function _.unlockCallback(bytes) external => DISPATCHER(true);

    /// Unresolved unlock callback in PM:
    unresolved external in PoolManager.unlock(bytes) => DISPATCH [
        MarginHookManager.unlockCallback(bytes)
    ] default HAVOC_ECF;
    /// Unresolved unlock callbacks:
    unresolved external in MarginHookManager.unlockCallback(bytes) => DISPATCH [
        MarginHookManager.handleRelease(MarginHookManager.ReleaseParams),
        MarginHookManager.handleAddLiquidity(address,PoolManager.PoolKey,uint256,uint256),
        MarginHookManager.handleMargin(address,MarginHookManager.MarginParams)
    ] default HAVOC_ECF;
}

definition alwaysReverting(method f) returns bool = false
    || f.selector == sig:beforeRemoveLiquidity(address,PoolManager.PoolKey,IPoolManager.ModifyLiquidityParams,bytes).selector
    || f.selector == sig:beforeAddLiquidity(address,PoolManager.PoolKey,IPoolManager.ModifyLiquidityParams,bytes).selector
    || f.selector == sig:afterSwap(address,PoolManager.PoolKey,IPoolManager.SwapParams,PoolManager.BalanceDelta,bytes).selector
    || f.selector == sig:afterRemoveLiquidity(address,PoolManager.PoolKey,IPoolManager.ModifyLiquidityParams,PoolManager.BalanceDelta,PoolManager.BalanceDelta,bytes).selector
    || f.selector == sig:afterAddLiquidity(address,PoolManager.PoolKey,IPoolManager.ModifyLiquidityParams,PoolManager.BalanceDelta,PoolManager.BalanceDelta,bytes).selector
    || f.selector == sig:afterInitialize(address,PoolManager.PoolKey,uint160,int24).selector
    || f.selector == sig:beforeDonate(address,PoolManager.PoolKey,uint256,uint256,bytes).selector
    || f.selector == sig:afterDonate(address,PoolManager.PoolKey,uint256,uint256,bytes).selector;

// excluding methods whose body is just `revert <msg>;
use builtin rule sanity filtered{f -> !alwaysReverting(f) && f.contract != PM}

rule alwaysRevert(method f) filtered{f -> alwaysReverting(f)}
{
    env e;
    calldataarg args;
    f@withrevert(e,args);

    assert lastReverted;
}
