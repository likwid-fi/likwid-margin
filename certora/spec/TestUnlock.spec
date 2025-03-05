methods {
    function MarginRouter.getSender() external returns (address) envfree;
    function MarginRouter.getPoolId() external returns (MarginRouter.PoolId) envfree;
    
    /// Unresolved unlock callback:
    function _.unlockCallback(bytes) external => DISPATCHER(true);

    /// Unresolved unlock callback in PM:
    unresolved external in PoolManager.unlock(bytes) => DISPATCH [
        MarginRouter.unlockCallback(bytes)
    ] default HAVOC_ECF;
    
    unresolved external in MarginRouter.unlockCallback(bytes) => DISPATCH [
        MarginRouter.handelSwap(address,MarginRouter.SwapParams)
    ] default HAVOC_ECF;
}

rule calldataMatches() {
    env e;
    MarginRouter.SwapParams params;
    /// Prove this is correct.
    uint256 amountOut = exactInput(e, params);

    assert getSender() == e.msg.sender;
    assert getPoolId() == params.poolId;
}