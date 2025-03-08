// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC6909Claims} from "v4-core/ERC6909Claims.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";

contract MirrorTokenManager is IMirrorTokenManager, ERC6909Claims, Owned {
    mapping(address => bool) public poolManagers;

    constructor(address initialOwner) Owned(initialOwner) {}

    modifier onlyPoolManager() {
        require(poolManagers[msg.sender], "UNAUTHORIZED");
        _;
    }

    function mint(uint256 id, uint256 amount) external onlyPoolManager {
        unchecked {
            _mint(msg.sender, id, amount);
        }
    }

    function burn(uint256 id, uint256 amount) external onlyPoolManager {
        unchecked {
            amount = Math.min(balanceOf[msg.sender][id], amount);
            _burn(msg.sender, id, amount);
        }
    }

    // ******************** OWNER CALL ********************
    function addPoolManger(address _manager) external onlyOwner {
        poolManagers[_manager] = true;
    }
}
