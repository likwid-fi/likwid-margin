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
import {CurrencyExtLibrary} from "./libraries/CurrencyExtLibrary.sol";
import {CurrencyPoolLibrary} from "./libraries/CurrencyPoolLibrary.sol";

import {PoolStatus} from "./types/PoolStatus.sol";
import {PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IERC6909Accrues} from "./interfaces/external/IERC6909Accrues.sol";
import {ILendingPoolManager} from "./interfaces/ILendingPoolManager.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";

contract LendingPoolManager is BasePoolManager, ERC6909Accrues, ILendingPoolManager {
    using PoolIdLibrary for PoolId;
    using CurrencyExtLibrary for Currency;
    using CurrencyPoolLibrary for Currency;
    using PerLibrary for *;
    using UQ112x112 for *;
    using PoolStatusLibrary for PoolStatus;

    event UpdateInterestRatio(
        uint256 indexed id,
        uint256 totalSupply,
        int256 interest,
        uint256 incrementRatioX112Old,
        uint256 incrementRatioX112New
    );

    event Deposit(
        PoolId indexed poolId,
        Currency indexed currency,
        address indexed sender,
        address recipient,
        uint256 amount,
        uint256 originalAmount,
        uint256 incrementRatioX112
    );

    event Withdraw(
        PoolId indexed poolId,
        Currency indexed currency,
        address indexed sender,
        address recipient,
        uint256 amount,
        uint256 originalAmount,
        uint256 incrementRatioX112
    );

    IMirrorTokenManager public immutable mirrorTokenManager;
    IPairPoolManager public pairPoolManager;
    mapping(uint256 => uint256) public incrementRatioX112Of;

    constructor(address initialOwner, IPoolManager _manager, IMirrorTokenManager _mirrorTokenManager)
        BasePoolManager(initialOwner, _manager)
    {
        mirrorTokenManager = _mirrorTokenManager;
    }

    modifier onlyStatusManager() {
        require(
            address(pairPoolManager.statusManager()) == msg.sender || address(pairPoolManager) == msg.sender,
            "UNAUTHORIZED"
        );
        _;
    }

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

    function _mintReturn(address receiver, uint256 id, uint256 amount) internal returns (uint256 originalAmount) {
        _mint(receiver, id, amount);
        originalAmount = amount.divRatioX112(incrementRatioX112Of[id]);
    }

    function _burnReturn(address sender, uint256 id, uint256 amount) internal returns (uint256 originalAmount) {
        _burn(sender, id, amount);
        originalAmount = amount.divRatioX112(incrementRatioX112Of[id]);
    }

    // ******************** EXTERNAL CALL ********************

    function computeRealAmount(PoolId poolId, Currency currency, uint256 originalAmount)
        public
        view
        returns (uint256 amount)
    {
        if (originalAmount > 0) {
            uint256 id = currency.toTokenId(poolId);
            amount = originalAmount.mulRatioX112(incrementRatioX112Of[id]);
        }
    }

    function getLendingAPR(PoolId poolId, Currency currency, uint256 inputAmount) public view returns (uint256 apr) {
        uint256 id = currency.toTokenId(poolId);
        PoolStatus memory status = pairPoolManager.getStatus(poolId);
        bool borrowForOne = currency == status.key.currency1;
        uint256 mirrorReserve = borrowForOne ? status.totalMirrorReserve1() : status.totalMirrorReserve0();
        uint256 borrowRate = pairPoolManager.marginFees().getBorrowRate(status, !borrowForOne);
        (uint256 reserve0, uint256 reserve1) =
            pairPoolManager.marginLiquidity().getInterestReserves(address(pairPoolManager), poolId, status);
        uint256 flowReserve = borrowForOne ? reserve1 : reserve0;
        uint256 totalSupply = balanceOf(address(this), id);
        uint256 allInterestReserve = flowReserve + inputAmount + totalSupply;
        if (allInterestReserve > 0) {
            apr = Math.mulDiv(borrowRate, mirrorReserve, allInterestReserve);
        }
    }

    // ******************** POOL CALL ********************

    function updateInterests(uint256 id, int256 interest) external onlyStatusManager {
        if (interest == 0) {
            return;
        }
        uint256 totalSupply = balanceOf(address(this), id);
        uint256 incrementRatioX112Old = incrementRatioX112Of[id];
        if (interest > 0) {
            incrementRatioX112Of[id] = incrementRatioX112Old.growRatioX112(uint256(interest), totalSupply);
        } else {
            incrementRatioX112Of[id] = incrementRatioX112Old.reduceRatioX112(uint256(-interest), totalSupply);
        }
        emit UpdateInterestRatio(id, totalSupply, interest, incrementRatioX112Old, incrementRatioX112Of[id]);
    }

    function mirrorIn(address receiver, PoolId poolId, Currency currency, uint256 amount)
        external
        onlyPairManager
        returns (uint256 originalAmount)
    {
        uint256 id = currency.toTokenId(poolId);
        mirrorTokenManager.transferFrom(msg.sender, address(this), id, amount);
        originalAmount = _mintReturn(receiver, id, amount);
        emit Deposit(poolId, currency, msg.sender, receiver, amount, originalAmount, incrementRatioX112Of[id]);
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
            mirrorTokenManager.transferFrom(msg.sender, address(this), currency.toTokenId(poolId), exchangeAmount);
        }
    }

    function realIn(address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        onlyPairManager
        returns (uint256 originalAmount)
    {
        uint256 id = currency.toTokenId(poolId);
        poolManager.transferFrom(msg.sender, address(this), currency.toId(), amount);
        originalAmount = _mintReturn(recipient, id, amount);
        emit Deposit(poolId, currency, msg.sender, recipient, amount, originalAmount, incrementRatioX112Of[id]);
    }

    function realOut(address sender, PoolId poolId, Currency currency, uint256 amount) external onlyPairManager {
        uint256 tokenId = currency.toTokenId(poolId);
        poolManager.transfer(msg.sender, currency.toId(), amount);
        uint256 originalAmount = _burnReturn(sender, tokenId, amount);
        emit Withdraw(poolId, currency, msg.sender, sender, amount, originalAmount, incrementRatioX112Of[tokenId]);
    }

    // ******************** USER CALL ********************

    function deposit(address sender, address recipient, PoolId poolId, Currency currency, uint256 amount)
        public
        payable
        returns (uint256 originalAmount)
    {
        uint256 sendAmount = currency.checkAmount(amount);
        bytes memory result =
            poolManager.unlock(abi.encodeCall(this.handleDeposit, (sender, recipient, poolId, currency, amount)));
        originalAmount = abi.decode(result, (uint256));
        if (msg.value > sendAmount) transferNative(msg.sender, msg.value - sendAmount);
        pairPoolManager.statusManager().updateLendingPoolStatus(poolId);
    }

    function deposit(address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        payable
        returns (uint256 originalAmount)
    {
        originalAmount = deposit(msg.sender, recipient, poolId, currency, amount);
    }

    function handleDeposit(address sender, address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        selfOnly
        returns (uint256 originalAmount)
    {
        uint256 id = currency.toTokenId(poolId);
        currency.settle(poolManager, sender, amount, false);
        currency.take(poolManager, address(this), amount, true);
        originalAmount = _mintReturn(recipient, id, amount);
        emit Deposit(poolId, currency, msg.sender, recipient, amount, originalAmount, incrementRatioX112Of[id]);
    }

    function withdraw(address recipient, PoolId poolId, Currency currency, uint256 amount) external {
        poolManager.unlock(abi.encodeCall(this.handleWithdraw, (msg.sender, recipient, poolId, currency, amount)));
        pairPoolManager.statusManager().updateLendingPoolStatus(poolId);
    }

    function handleWithdraw(address sender, address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        selfOnly
    {
        uint256 id = currency.toTokenId(poolId);
        uint256 balance = poolManager.balanceOf(address(this), currency.toId());
        if (balance < amount) {
            bool success = pairPoolManager.mirrorInRealOut(poolId, currency, amount - balance);
            require(success, "NOT_ENOUGH_RESERVE");
        }
        currency.settle(poolManager, address(this), amount, true);
        currency.take(poolManager, recipient, amount, false);
        uint256 originalAmount = _burnReturn(sender, id, amount);
        emit Withdraw(poolId, currency, msg.sender, recipient, amount, originalAmount, incrementRatioX112Of[id]);
    }

    function balanceMirror(PoolId poolId, Currency currency, uint256 amount) external payable {
        poolManager.unlock(abi.encodeCall(this.handleBalanceMirror, (msg.sender, poolId, currency, amount)));
        pairPoolManager.statusManager().updateLendingPoolStatus(poolId);
    }

    function handleBalanceMirror(address sender, PoolId poolId, Currency currency, uint256 amount) external selfOnly {
        uint256 id = currency.toTokenId(poolId);
        mirrorTokenManager.burn(id, amount);
        currency.settle(poolManager, sender, amount, false);
        currency.take(poolManager, address(this), amount, true);
    }

    // ******************** OWNER CALL ********************

    function setPairPoolManger(IPairPoolManager _manager) external onlyOwner {
        pairPoolManager = _manager;
        mirrorTokenManager.setOperator(address(_manager), true);
    }
}
