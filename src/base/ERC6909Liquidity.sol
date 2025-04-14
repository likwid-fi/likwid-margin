// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {IERC6909} from "../interfaces/external/IERC6909.sol";
import {UQ112x112} from "../libraries/UQ112x112.sol";
import {TimeLibrary} from "../libraries/TimeLibrary.sol";

/// @notice Minimalist and gas efficient standard ERC6909 implementation.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC6909.sol)
abstract contract ERC6909Liquidity is IERC6909 {
    using UQ112x112 for *;
    using TimeLibrary for uint32;

    /*//////////////////////////////////////////////////////////////
                             ERC6909 STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(address => mapping(address => bool)) public isOperator;

    mapping(address => mapping(uint256 => uint256)) public balanceOriginal;

    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowanceOriginal;

    /*//////////////////////////////////////////////////////////////
                             EXTEND STORAGE
    //////////////////////////////////////////////////////////////*/

    error NotAllowed();

    uint32 public minHoldingDuration = 30; // seconds
    mapping(address => bool) public poolManagers;
    mapping(uint256 => uint256) public accruesRatioX112Of;
    mapping(address => mapping(uint256 => uint32)) public datetimeStore;

    /*//////////////////////////////////////////////////////////////
                              ERC6909 LOGIC
    //////////////////////////////////////////////////////////////*/

    function balanceOf(address owner, uint256 id) public view virtual returns (uint256) {
        uint256 balance = balanceOriginal[owner][id];
        return balance.mulRatioX112(accruesRatioX112Of[id]);
    }

    function allowance(address owner, address spender, uint256 id) external view returns (uint256) {
        uint256 amount = allowanceOriginal[owner][spender][id];
        return amount.mulRatioX112(accruesRatioX112Of[id]);
    }

    function transfer(address receiver, uint256 id, uint256 amount) public virtual returns (bool) {
        if (datetimeStore[msg.sender][id].getTimeElapsed() < minHoldingDuration || poolManagers[receiver]) {
            revert NotAllowed();
        }
        amount = amount.divRatioX112(accruesRatioX112Of[id]);

        balanceOriginal[msg.sender][id] -= amount;

        balanceOriginal[receiver][id] += amount;

        emit Transfer(msg.sender, msg.sender, receiver, id, amount);

        return true;
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) public virtual returns (bool) {
        if (datetimeStore[sender][id].getTimeElapsed() < minHoldingDuration || poolManagers[receiver]) {
            revert NotAllowed();
        }
        amount = amount.divRatioX112(accruesRatioX112Of[id]);

        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowanceOriginal[sender][msg.sender][id];
            if (allowed != type(uint256).max) allowanceOriginal[sender][msg.sender][id] = allowed - amount;
        }

        balanceOriginal[sender][id] -= amount;

        balanceOriginal[receiver][id] += amount;

        emit Transfer(msg.sender, sender, receiver, id, amount);

        return true;
    }

    function approve(address spender, uint256 id, uint256 amount) public virtual returns (bool) {
        amount = amount.divRatioX112(accruesRatioX112Of[id]);

        allowanceOriginal[msg.sender][spender][id] = amount;

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
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(address caller, address receiver, uint256 id, uint256 amount)
        internal
        virtual
        returns (uint256 originalAmount)
    {
        uint256 ratioX112 = accruesRatioX112Of[id];
        if (ratioX112 == 0) {
            ratioX112 = accruesRatioX112Of[id] = UQ112x112.Q112;
            originalAmount = amount;
        } else {
            originalAmount = amount.divRatioX112(ratioX112);
        }

        balanceOriginal[receiver][id] += originalAmount;

        emit Transfer(caller, address(0), receiver, id, originalAmount);
    }

    function _burn(address caller, address sender, uint256 id, uint256 amount)
        internal
        virtual
        returns (uint256 originalAmount)
    {
        if (datetimeStore[sender][id].getTimeElapsed() < minHoldingDuration) {
            revert NotAllowed();
        }
        originalAmount = amount.divRatioX112(accruesRatioX112Of[id]);
        if (amount > 0 && originalAmount == 0) {
            originalAmount = 1;
        }

        balanceOriginal[sender][id] -= originalAmount;

        emit Transfer(caller, sender, address(0), id, originalAmount);
    }
}
