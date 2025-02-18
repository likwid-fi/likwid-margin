// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC6909Claims} from "v4-core/ERC6909Claims.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";

contract MirrorTokenManager is IMirrorTokenManager, ERC6909Claims, Owned {
    mapping(address => bool) public hooks;

    constructor(address initialOwner) Owned(initialOwner) {}

    modifier onlyHook() {
        require(hooks[msg.sender], "UNAUTHORIZED");
        _;
    }

    function mint(uint256 id, uint256 amount) external onlyHook {
        unchecked {
            _mint(msg.sender, id, amount);
        }
    }

    function burn(uint256 id, uint256 amount) external onlyHook {
        unchecked {
            _burn(msg.sender, id, amount);
        }
    }

    // ******************** OWNER CALL ********************
    function addHooks(address _hook) external onlyOwner {
        hooks[_hook] = true;
    }
}
