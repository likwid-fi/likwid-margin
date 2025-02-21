import "./ERC20Cvl.spec";

methods {
    
    // function _.unlock(bytes) external=> DISPATCHER(true); //  returns (bytes memory) 

    // function unlockCallback(bytes) external => DISPATCHER(true); //  returns (bytes memory)

    // function handleMargin(address _positionManager, MarginParams /* struct.. */ calldata params) external =>
    //     NONDET;
        // returns (uint256 marginWithoutFee, uint256 borrowAmount)

    // from https://github.com/Certora/ProjectSetup/blob/main/certora/specs/ERC721/erc721.spec
    // likely unsound, but assumes no callback
    function _.onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes data
    ) external => NONDET; /* expects bytes4 */
}

// excluding methods whose bodiy is just `revert <msg>;` 
use builtin rule sanity filtered { f -> 
    f.contract == currentContract 
    && f.selector != beforeRemoveLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes).selector
    && f.selector != beforeAddLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),bytes)
    && f.selector != afterSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),int256,bytes)
    && f.selector != afterRemoveLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),int256,int256,bytes)
    && f.selector != afterAddLiquidity(address,(address,address,uint24,int24,address),(int24,int24,int256,bytes32),int256,int256,bytes)
    && f.selector != afterInitialize(address,(address,address,uint24,int24,address),uint160,int24)
    && f.selector != beforeDonate(address,(address,address,uint24,int24,address),uint256,uint256,bytes)
    && f.selector != afterDonate(address,(address,address,uint24,int24,address),uint256,uint256,bytes)
}