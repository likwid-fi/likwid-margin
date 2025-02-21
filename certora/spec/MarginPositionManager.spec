import "./ERC20Cvl.spec";

methods {
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