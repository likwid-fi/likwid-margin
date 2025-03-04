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

use builtin rule sanity filtered { f -> f.contract == currentContract }