// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {ERC6909Accrues} from "./base/ERC6909Accrues.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";

contract LendingTokenManager is ERC6909Accrues, Owned {
    using PerLibrary for *;
    using UQ112x112 for *;

    mapping(address => bool) public poolManagers;
    mapping(address => mapping(uint256 => uint256)) public deviationOf;
    mapping(uint256 => uint256) public incrementRatioX112Of;

    constructor(address initialOwner) Owned(initialOwner) {}

    modifier onlyPoolManager() {
        require(poolManagers[msg.sender], "UNAUTHORIZED");
        _;
    }

    // ******************** ERC6909 INTERNAL ********************

    function _mint(address receiver, uint256 id, uint256 amount) internal override {
        if (incrementRatioX112Of[id] == 0) {
            incrementRatioX112Of[id] = UQ112x112.Q112;
        } else {
            amount = amount.divRatioX112(incrementRatioX112Of[id]);
            deviationOf[receiver][id] += 1;
        }
        super._mint(address(this), id, amount);
        super._mint(receiver, id, amount);
    }

    function _burn(address sender, uint256 id, uint256 amount) internal override {
        amount = amount.divRatioX112(incrementRatioX112Of[id]);
        uint256 balance = balanceStore[sender][id];
        if (amount.isWithinTolerance(balance, deviationOf[sender][id])) {
            amount = balance;
            deviationOf[sender][id] = 0;
        }
        super._burn(address(this), id, amount);
        super._burn(sender, id, amount);
    }

    // ******************** ERC6909 LOGIC ********************

    function balanceOf(address owner, uint256 id) public view override returns (uint256) {
        uint256 balance = super.balanceOf(owner, id);
        return balance.mulRatioX112(incrementRatioX112Of[id]);
    }

    function transfer(address receiver, uint256 id, uint256 amount) public override returns (bool) {
        amount = amount.divRatioX112(incrementRatioX112Of[id]);
        return super.transfer(receiver, id, amount);
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        public
        override
        returns (bool)
    {
        amount = amount.divRatioX112(incrementRatioX112Of[id]);
        return super.transferFrom(sender, receiver, id, amount);
    }

    function approve(address spender, uint256 id, uint256 amount) public override returns (bool) {
        amount = amount.divRatioX112(incrementRatioX112Of[id]);
        return super.approve(spender, id, amount);
    }

    // ******************** POOL CALL ********************

    function updateInterests(uint256 id, uint256 interest) external onlyPoolManager {
        uint256 totalSupply = balanceOf(address(this), id);
        incrementRatioX112Of[id] = incrementRatioX112Of[id].growRatioX112(interest, totalSupply);
    }

    // ******************** OWNER CALL ********************

    function addPoolManger(address _manager) external onlyOwner {
        poolManagers[_manager] = true;
    }
}
