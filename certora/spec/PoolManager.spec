using PoolManager as PM;

methods {
    function PM._swap(int256 amountToSwap) internal returns (int256) => assertZeroDelta(amountToSwap);
}

function zeroCurrencyDeltaForAll() returns bool {
    /// Overall require on storage by direct access.
    return forall address token. forall address account. PM._currencyDelta[token][account] == 0;
}

function assertZeroDelta(int256 amountToSwap) returns int256 {
    assert amountToSwap == 0, "The hook must not pass any amount to the pool swap function";
    return 0;
}

/// @title Unlocking the PoolManager in removeLiquidity() should always result in zeroed-out virtual accounting.
rule removeLiquidityEndsWithZeroVirtualAccounting() 
{
    env e;
    MarginHookManager.RemoveLiquidityParams params;
    
    require zeroCurrencyDeltaForAll();
        removeLiquidity(e, params);
    assert zeroCurrencyDeltaForAll();
    /// Easier to debug
    //address token;
    //address account;
    //assert PM._currencyDelta[token][account] == 0;
}