// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {MockERC721} from "solmate/src/test/utils/mocks/MockERC721.sol";

interface ILockTarget {
    function lockNFT(address nftContract, uint256 tokenId, uint64 lockDuration) external returns (uint256);
}

/// @notice Malicious-style ERC721 used by tests: when its `safeTransferFrom`
///         is invoked, it re-enters {ILockTarget.lockNFT} for the same token.
///         Used to verify that LikwidHelper rejects double-locking via
///         re-entrant ERC721 contracts.
contract ReentrantLockNFT is MockERC721 {
    address public target;
    bool public reenter;

    constructor() MockERC721("Reentrant", "REE") {}

    function setTarget(address _target) external {
        target = _target;
    }

    function setReenter(bool _reenter) external {
        reenter = _reenter;
    }

    function safeTransferFrom(address from, address to, uint256 id) public override {
        if (reenter) {
            // Disable to avoid infinite recursion, then call back into the
            // helper as the original sender.
            reenter = false;
            ILockTarget(target).lockNFT(address(this), id, 1 days);
        }
        super.safeTransferFrom(from, to, id);
    }
}
