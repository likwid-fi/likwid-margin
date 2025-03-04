import "./CVLERC20.spec";
import "./MathSummary.spec";
import "./PoolManager.spec";

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
}

use builtin rule sanity filtered{f -> f.contract == currentContract}