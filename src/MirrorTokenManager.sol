// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

import {Owned} from "solmate/src/auth/Owned.sol";

import {ERC6909} from "./base/ERC6909.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";

contract MirrorTokenManager is IMirrorTokenManager, ERC6909, Owned {
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

    function mintInStatus(address receiver, uint256 id, uint256 amount) external onlyPoolManager {
        unchecked {
            _mint(receiver, id, amount);
        }
    }

    function burn(uint256 id, uint256 amount) external onlyPoolManager {
        unchecked {
            _burn(msg.sender, id, amount);
        }
    }

    function burn(address lendingPoolManager, uint256 id, uint256 amount)
        external
        onlyPoolManager
        returns (uint256 pairAmount, uint256 lendingAmount)
    {
        uint256 balance = balanceOf[msg.sender][id];
        if (balance >= amount) {
            pairAmount = amount;
            unchecked {
                _burn(msg.sender, id, amount);
            }
        } else {
            if (balance > 0) {
                pairAmount = balance;
                unchecked {
                    _burn(msg.sender, id, balance);
                }
                amount -= balance;
            }
            if (amount > 0) {
                balance = balanceOf[lendingPoolManager][id];
                if (balance > 0) {
                    amount = amount < balance ? amount : balance;
                    lendingAmount = amount;
                    unchecked {
                        _burn(lendingPoolManager, id, amount);
                    }
                }
            }
        }
    }

    // ******************** OWNER CALL ********************
    function addPoolManager(address _manager) external onlyOwner {
        poolManagers[_manager] = true;
        address statusManager = address(IPairPoolManager(_manager).statusManager());
        require(statusManager != address(0), "STATUS_MANAGER_ERROR");
        poolManagers[statusManager] = true;
        address lendingPoolManager = address(IPairPoolManager(_manager).lendingPoolManager());
        require(lendingPoolManager != address(0), "LENDING_MANAGER_ERROR");
        poolManagers[lendingPoolManager] = true;
    }
}
