// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
// Local
import {BasePoolManager} from "./base/BasePoolManager.sol";
import {ERC6909Accrues} from "./base/ERC6909Accrues.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {CurrencyUtils} from "./libraries/CurrencyUtils.sol";

import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IERC6909Accrues} from "./interfaces/external/IERC6909Accrues.sol";
import {ILendingPoolManager} from "./interfaces/ILendingPoolManager.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";

contract LendingPoolManager is BasePoolManager, ERC6909Accrues, ILendingPoolManager {
    using PoolIdLibrary for PoolId;
    using CurrencyUtils for Currency;
    using PerLibrary for *;
    using UQ112x112 for *;

    IMirrorTokenManager public immutable mirrorTokenManager;
    IPairPoolManager public pairPoolManager;
    mapping(uint256 => uint256) public incrementRatioX112Of;

    constructor(address initialOwner, IPoolManager _manager, IMirrorTokenManager _mirrorTokenManager)
        BasePoolManager(initialOwner, _manager)
    {
        mirrorTokenManager = _mirrorTokenManager;
    }

    modifier onlyPairManager() {
        require(address(pairPoolManager) == msg.sender, "UNAUTHORIZED");
        _;
    }

    function transferNative(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success, "TRANSFER_FAILED");
    }

    // ******************** ERC6909 INTERNAL ********************

    function _mint(address receiver, uint256 id, uint256 amount) internal override {
        if (incrementRatioX112Of[id] == 0) {
            incrementRatioX112Of[id] = UQ112x112.Q112;
        } else {
            amount = amount.divRatioX112(incrementRatioX112Of[id]);
        }
        super._mint(address(this), id, amount);
        super._mint(receiver, id, amount);
    }

    function _burn(address sender, uint256 id, uint256 amount) internal override {
        amount = amount.divRatioX112(incrementRatioX112Of[id]);

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
    // ******************** INTERNAL CALL ********************

    function _mintReturn(address receiver, uint256 id, uint256 amount) internal returns (uint256) {
        _mint(receiver, id, amount);
        uint256 incrementRatioX112 = incrementRatioX112Of[id];
        return amount.divRatioX112(incrementRatioX112).mulRatioX112(incrementRatioX112);
    }

    // ******************** EXTERNAL CALL ********************

    function computeRealAmount(PoolId poolId, Currency currency, uint256 originalAmount)
        public
        view
        returns (uint256 amount)
    {
        uint256 id = currency.toPoolId(poolId);
        amount = originalAmount.mulRatioX112(incrementRatioX112Of[id]);
    }

    // ******************** POOL CALL ********************

    function updateInterests(uint256 id, uint256 interest) external onlyPairManager {
        uint256 totalSupply = balanceOf(address(this), id);
        incrementRatioX112Of[id] = incrementRatioX112Of[id].growRatioX112(interest, totalSupply);
    }

    function mirrorIn(PoolId poolId, Currency currency, uint256 amount)
        external
        onlyPairManager
        returns (uint256 lendingAmount)
    {
        uint256 id = currency.toPoolId(poolId);
        mirrorTokenManager.transferFrom(msg.sender, address(this), id, amount);
        lendingAmount = _mintReturn(msg.sender, id, amount);
    }

    function mirrorInRealOut(PoolId poolId, Currency currency, uint256 amount)
        external
        onlyPairManager
        returns (uint256 exchangeAmount)
    {
        uint256 id = currency.toId();
        uint256 balance = poolManager.balanceOf(address(this), id);
        exchangeAmount = Math.min(balance, amount);
        if (exchangeAmount > 0) {
            poolManager.transfer(msg.sender, id, exchangeAmount);
            mirrorTokenManager.transferFrom(msg.sender, address(this), currency.toPoolId(poolId), exchangeAmount);
        }
    }

    function realIn(address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        onlyPairManager
        returns (uint256 lendingAmount)
    {
        poolManager.transferFrom(msg.sender, address(this), currency.toId(), amount);
        lendingAmount = _mintReturn(recipient, currency.toPoolId(poolId), amount);
    }

    function realOut(address sender, PoolId poolId, Currency currency, uint256 amount) external onlyPairManager {
        poolManager.transfer(msg.sender, currency.toId(), amount);
        _burn(sender, currency.toPoolId(poolId), amount);
    }

    // ******************** USER CALL ********************

    function deposit(address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        payable
        returns (uint256 lendingAmount)
    {
        uint256 sendAmount = currency.checkAmount(amount);
        bytes memory result =
            poolManager.unlock(abi.encodeCall(this.handleDeposit, (msg.sender, recipient, poolId, currency, amount)));
        lendingAmount = abi.decode(result, (uint256));
        if (msg.value > sendAmount) transferNative(msg.sender, msg.value - sendAmount);
    }

    function handleDeposit(address sender, address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        selfOnly
        returns (uint256 lendingAmount)
    {
        uint256 id = currency.toPoolId(poolId);
        currency.settle(poolManager, sender, amount, false);
        currency.take(poolManager, address(this), amount, true);
        lendingAmount = _mintReturn(recipient, id, amount);
    }

    function withdrawOriginal(address recipient, PoolId poolId, Currency currency, uint256 originalAmount) external {
        uint256 amount = computeRealAmount(poolId, currency, originalAmount);
        poolManager.unlock(abi.encodeCall(this.handleWithdraw, (msg.sender, recipient, poolId, currency, amount)));
    }

    function withdraw(address recipient, PoolId poolId, Currency currency, uint256 amount) external {
        poolManager.unlock(abi.encodeCall(this.handleWithdraw, (msg.sender, recipient, poolId, currency, amount)));
    }

    function handleWithdraw(address sender, address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        selfOnly
    {
        uint256 id = currency.toPoolId(poolId);
        currency.settle(poolManager, address(this), amount, true);
        currency.take(poolManager, recipient, amount, false);
        _burn(sender, id, amount);
    }

    // ******************** OWNER CALL ********************

    function setPairPoolManger(IPairPoolManager _manager) external onlyOwner {
        pairPoolManager = _manager;
    }
}
