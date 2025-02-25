methods {
    function getStatus(PoolIdLibrary.PoolId poolId) external returns (MarginHookManager.HookStatus memory) envfree;
    function getReserves(PoolIdLibrary.PoolId poolId) external returns (uint256, uint256) envfree;
    function getAmountIn(PoolIdLibrary.PoolId poolId, bool zeroForOne, uint256 amountOut) external returns (uint256 amountIn) envfree;
    function getAmountOut(PoolIdLibrary.PoolId poolId, bool zeroForOne, uint256 amountIn) external returns (uint256 amountOut) envfree;
}

// In setup spec, add the following block
/*
methods {
    function MarginHookManager._getAmountOut(MarginHookManager.HookStatus memory status, bool zeroForOne, uint256 amountIn) internal returns (uint256) with (env e)
        => getAmountOutCVL(e.block.timestamp, status, zeroForOne, amountIn);

    function MarginHookManager._getAmountIn(MarginHookManager.HookStatus memory status, bool zeroForOne, uint256 amountOut) internal returns (uint256) with (env e)
        => getAmountOutCVL(e.block.timestamp, status, zeroForOne, amountOut);
}
*/

definition MAX_FEE_UNITS() returns uint256 = 10^6;

/// CVL implementation of _getReserves()
function getReservesByStatus(MarginHookManager.HookStatus status, bool zeroForOne) returns (uint256,uint256) {
    uint256 reserve0 = require_uint256(status.realReserve0 + status.mirrorReserve0);
    uint256 reserve1 = require_uint256(status.realReserve1 + status.mirrorReserve1);
    if(zeroForOne) {
        return (reserve0,reserve1);
    }
    return (reserve1,reserve0);
}

function validReservesAndAmounts(uint256 amount, uint256 reserveX, uint256 reserveY) returns bool {
    return amount > 0 && reserveX > 0 && reserveY > 0 && amount < reserveX;
}

/// Summary for _getAmountIn(HookStatus memory status, bool zeroForOne, uint256 amountOut)
function getAmountInCVL(uint256 timestamp, MarginHookManager.HookStatus status, bool zeroForOne, uint256 amountOut) returns uint256 {
    uint256 reserveIn; uint256 reserveOut;
    reserveIn, reserveOut = getReservesByStatus(status, zeroForOne)
    require validReservesAndAmounts(amountOut, reserveOut, reserveIn);
    uint256 fee = dynamicFeeCVL(timestamp, status.marginTimestampLast, zeroForOne ? reserveIn : reserveOut, zeroForOne ? reserveOut : reserveIn);
    return amountInCVL(amountOut, reserveOut, reserveIn, fee);
}

/// Summary for _getAmountOut(HookStatus memory status, bool zeroForOne, uint256 amountIn)
function getAmountOutCVL(uint256 timestamp, MarginHookManager.HookStatus status, bool zeroForOne, uint256 amountIn) returns uint256 {
    uint256 amountOut;
    /// Complete the summary similarly to the getAmountInCVL()...
    /// Pay attention to the roles of reserveIn and reserveOut!
    return amountOut;
} 

/// Ghost summary for MarginFees.dynamicFee(status) - assumes dependence on four parameters only.
ghost dynamicFeeCVL(uint256 /* timestamp */, uint256 /* last timestamp */, uint256 /* reserve0 */, uint256 /* reserve1 */) returns uint256 {
    axiom forall uint256 timestamp. forall uint256 lastTimestmap. forall uint256 reserve0. forall uint256 reserve1.
        dynamicFeeCVL(timestamp,lastTimestmap,reserve0,reserve1) < MAX_FEE_UNITS();
}

/// Ghost summary for amounts based on reserves and fees
/// Think of axioms for limiting the behavior of the ghosts.
ghost amountInCVL(uint256 /* amountOut */, uint256 /* reserveOut */, uint256 /* reserveIn */ , uint256 /* fee */) returns uint256;
ghost amountOutCVL(uint256 /* amountIn */, uint256 /* reserveIn */, uint256 /* reserveOut */ , uint256 /* fee */) returns uint256;