// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// Local
import {BasePool} from "./base/BasePool.sol";
import {ERC6909Accrues} from "./base/ERC6909Accrues.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";

import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IERC6909Accrues} from "./interfaces/external/IERC6909Accrues.sol";
import {ILendingPoolManager} from "./interfaces/ILendingPoolManager.sol";

contract LendingPoolManager is BasePool, ERC6909Accrues, ILendingPoolManager {
    using PerLibrary for *;
    using UQ112x112 for *;

    IPairPoolManager public pairPoolManager;
    mapping(address => mapping(uint256 => uint256)) public deviationOf;
    mapping(uint256 => uint256) public incrementRatioX112Of;

    constructor(address initialOwner, IPoolManager _manager) BasePool(initialOwner, _manager) {}

    modifier onlyPairManager() {
        require(address(pairPoolManager) == msg.sender, "UNAUTHORIZED");
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

    function balanceOf(address owner, uint256 id)
        public
        view
        override(ERC6909Accrues, IERC6909Accrues)
        returns (uint256)
    {
        uint256 balance = super.balanceOf(owner, id);
        return balance.mulRatioX112(incrementRatioX112Of[id]);
    }

    function transfer(address receiver, uint256 id, uint256 amount)
        public
        override(ERC6909Accrues, IERC6909Accrues)
        returns (bool)
    {
        amount = amount.divRatioX112(incrementRatioX112Of[id]);
        return super.transfer(receiver, id, amount);
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        public
        override(ERC6909Accrues, IERC6909Accrues)
        returns (bool)
    {
        amount = amount.divRatioX112(incrementRatioX112Of[id]);
        return super.transferFrom(sender, receiver, id, amount);
    }

    function approve(address spender, uint256 id, uint256 amount)
        public
        override(ERC6909Accrues, IERC6909Accrues)
        returns (bool)
    {
        amount = amount.divRatioX112(incrementRatioX112Of[id]);
        return super.approve(spender, id, amount);
    }

    // ******************** POOL CALL ********************

    function updateInterests(uint256 id, uint256 interest) external onlyPairManager {
        uint256 totalSupply = balanceOf(address(this), id);
        incrementRatioX112Of[id] = incrementRatioX112Of[id].growRatioX112(interest, totalSupply);
    }

    // ******************** USER CALL ********************

    // Deposit and withdraw

    // ******************** OWNER CALL ********************

    function setPairPoolManger(IPairPoolManager _manager) external onlyOwner {
        pairPoolManager = _manager;
    }
}
