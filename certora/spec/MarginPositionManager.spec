import "./CVLERC20.spec";
import "./PoolManager.spec";

methods {
    /// Unresolved unlock callback in PM:
    unresolved external in PoolManager.unlock(bytes) => DISPATCH [
        MarginHookManager.unlockCallback(bytes)
    ] default HAVOC_ECF;
    
    /// Unresolved unlock callback:
    function _.unlockCallback(bytes) external => DISPATCHER(true);

    /// Unresolved unlock callbacks:
    unresolved external in MarginHookManager.unlockCallback(bytes) => DISPATCH [
        MarginHookManager.handleRelease(MarginHookManager.ReleaseParams),
        MarginHookManager.handleAddLiquidity(address,PoolManager.PoolKey,uint256,uint256),
        MarginHookManager.handleMargin(address,MarginHookManager.MarginParams)
    ] default HAVOC_ECF;

    function _.onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes data
    ) external => NONDET; /* expects bytes4 */
}

// excluding methods whose body is just `revert <msg>;
use builtin rule sanity filtered { f -> f.contract == currentContract } 

