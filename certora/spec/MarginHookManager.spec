import "./ERC20Cvl.spec";

// excluding methods whose body is just `revert <msg>;` 
use builtin rule sanity filtered { f -> 
    f.contract == currentContract 
    && f.selector != beforeRemoveLiquidity(address,address,address,uint24,int24,address,int24,int24,int256,bytes32,bytes).selector
    && f.selector != beforeAddLiquidity(address,address,address,uint24,int24,address,int24,int24,int256,bytes32,bytes)
    && f.selector != afterSwap(address,address,address,uint24,int24,address,bool,int256,uint160,int256,bytes)
    && f.selector != afterRemoveLiquidity(address,address,address,uint24,int24,address,int24,int24,int256,bytes32,int256,int256,bytes)
    && f.selector != afterAddLiquidity(address,address,address,uint24,int24,address,int24,int24,int256,bytes32,int256,int256,bytes)
    && f.selector != afterInitialize(address,address,address,uint24,int24,address,uint160,int24)
    && f.selector != beforeDonate(address,address,address,uint24,int24,address,uint256,uint256,bytes)
    && f.selector != afterDonate(address,address,address,uint24,int24,address,uint256,uint256,bytes)
}