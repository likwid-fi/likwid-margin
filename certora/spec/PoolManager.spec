using PoolManager as PM;

function zeroCurrencyDeltaForAll() returns bool {
    /// Overall require on storage by direct access.
    return forall address token. forall address account. PM._currencyDelta[token][account] == 0;
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