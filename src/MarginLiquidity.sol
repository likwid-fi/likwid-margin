// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC6909Claims} from "v4-core/ERC6909Claims.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {IMarginFees} from "./interfaces/IMarginFees.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";

contract MarginLiquidity is IMarginLiquidity, ERC6909Claims, Owned {
    IMarginFees public immutable marginFees;
    mapping(address => bool) public hooks;

    constructor(address initialOwner, IMarginFees _marginFees) Owned(initialOwner) {
        marginFees = _marginFees;
    }

    modifier onlyHook() {
        require(hooks[msg.sender], "UNAUTHORIZED");
        _;
    }

    function addHooks(address _hook) external onlyOwner {
        hooks[_hook] = true;
    }

    function mint(address receiver, uint256 id, uint256 amount) external onlyHook {
        unchecked {
            _mint(receiver, id, amount);
        }
    }

    function burn(address sender, uint256 id, uint256 amount) external onlyHook {
        unchecked {
            _burn(sender, id, amount);
        }
    }

    function addLiquidity(address receiver, uint256 id, uint8 level, uint256 amount) external onlyHook {
        uint256 levelId = marginFees.getLevelPool(id, level);
        unchecked {
            _mint(msg.sender, id, amount);
            _mint(msg.sender, levelId, amount);
            _mint(receiver, levelId, amount);
        }
    }

    function removeLiquidity(address sender, uint256 id, uint8 level, uint256 amount) external onlyHook {
        uint256 levelId = marginFees.getLevelPool(id, level);
        unchecked {
            _burn(msg.sender, id, amount);
            _burn(msg.sender, levelId, amount);
            _burn(sender, levelId, amount);
        }
    }
}
