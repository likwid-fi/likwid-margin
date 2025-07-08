// SPDX-License-Identifier: MIT
// Likwid Contracts
pragma solidity >=0.8.0;

import {IERC6909} from "../interfaces/external/IERC6909.sol";

/// @notice Minimalist and gas efficient standard ERC6909 implementation.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC6909.sol)
abstract contract ERC6909Liquidity is IERC6909 {
    error ErrorReceiver();

    /*//////////////////////////////////////////////////////////////
                             ERC6909 STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(address => mapping(address => bool)) public isOperator;

    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;

    /*//////////////////////////////////////////////////////////////
                              ERC6909 LOGIC
    //////////////////////////////////////////////////////////////*/

    function transfer(address receiver, uint256 id, uint256 amount) public virtual returns (bool) {
        if (receiver == address(this)) revert ErrorReceiver();

        balanceOf[msg.sender][id] -= amount;

        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, msg.sender, receiver, id, amount);

        return true;
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) public virtual returns (bool) {
        if (receiver == address(this)) revert ErrorReceiver();

        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][id];
            if (allowed != type(uint256).max) allowance[sender][msg.sender][id] = allowed - amount;
        }

        balanceOf[sender][id] -= amount;

        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, sender, receiver, id, amount);

        return true;
    }

    function approve(address spender, uint256 id, uint256 amount) public virtual returns (bool) {
        allowance[msg.sender][spender][id] = amount;

        emit Approval(msg.sender, spender, id, amount);

        return true;
    }

    function setOperator(address operator, bool approved) public virtual returns (bool) {
        isOperator[msg.sender][operator] = approved;

        emit OperatorSet(msg.sender, operator, approved);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                              ERC165 LOGIC
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165 Interface ID for ERC165
            || interfaceId == 0x0f632fb3; // ERC165 Interface ID for ERC6909
    }

    /*//////////////////////////////////////////////////////////////
                        EXTEND LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalSupply(uint256 id) public view virtual returns (uint256) {
        return balanceOf[address(this)][id];
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(address caller, address receiver, uint256 id, uint256 amount) internal virtual {
        balanceOf[address(this)][id] += amount;
        balanceOf[receiver][id] += amount;

        emit Transfer(caller, address(0), receiver, id, amount);
    }

    function _burn(address caller, address sender, uint256 id, uint256 amount) internal virtual {
        balanceOf[address(this)][id] -= amount;
        balanceOf[sender][id] -= amount;

        emit Transfer(caller, sender, address(0), id, amount);
    }
}
