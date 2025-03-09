// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {ERC6909Accrues} from "./base/ERC6909Accrues.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";

contract MirrorTokenManager is IMirrorTokenManager, ERC6909Accrues, Owned {
    using PerLibrary for *;

    mapping(address => bool) public poolManagers;

    constructor(address initialOwner) Owned(initialOwner) {}

    function _burn(address sender, uint256 id, uint256 amount) internal override {
        uint256 balance = balanceOf(sender, id);
        if (amount.isWithinTolerance(balance, 100)) {
            amount = balance;
        }
        super._burn(sender, id, amount);
    }

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
            _burn(msg.sender, id, amount);
        }
    }

    // ******************** OWNER CALL ********************
    function addPoolManger(address _manager) external onlyOwner {
        poolManagers[_manager] = true;
    }
}
