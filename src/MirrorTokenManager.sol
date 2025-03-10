// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Owned} from "solmate/src/auth/Owned.sol";

import {ERC6909Accrues} from "./base/ERC6909Accrues.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";

contract MirrorTokenManager is IMirrorTokenManager, ERC6909Accrues, Owned {
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

    function burn(address lendingPoolManager, uint256 id, uint256 amount) external onlyPoolManager {
        uint256 balance = balanceOf(msg.sender, id);
        if (balance >= amount) {
            unchecked {
                _burn(msg.sender, id, amount);
            }
        } else {
            if (balance > 0) {
                unchecked {
                    _burn(msg.sender, id, balance);
                }
                amount -= balance;
            }
            if (amount > 0) {
                balance = balanceOf(lendingPoolManager, id);
                if (balance > 0) {
                    amount = amount < balance ? amount : balance;
                    unchecked {
                        _burn(lendingPoolManager, id, amount);
                    }
                }
            }
        }
    }

    // ******************** OWNER CALL ********************
    function addPoolManger(address _manager) external onlyOwner {
        poolManagers[_manager] = true;
    }
}
