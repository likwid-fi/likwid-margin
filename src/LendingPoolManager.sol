// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
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
import {IPoolStatusManager} from "./interfaces/IPoolStatusManager.sol";
import {IERC6909} from "./interfaces/external/IERC6909.sol";
import {ILendingPoolManager} from "./interfaces/ILendingPoolManager.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";

contract LendingPoolManager is BasePoolManager, ERC6909Accrues, ILendingPoolManager {
    using PoolIdLibrary for PoolId;
    using SafeCast for uint256;
    using CurrencyExtLibrary for Currency;
    using CurrencyPoolLibrary for Currency;
    using PerLibrary for *;
    using UQ112x112 for *;
    using PoolStatusLibrary for PoolStatus;

    error InsufficientFunds();

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

    modifier onlyPositionManager() {
        require(pairPoolManager.positionManagers(msg.sender), "UNAUTHORIZED");
        _;
    }

    // ******************** EXTERNAL CALL ********************

    function computeRealAmount(PoolId poolId, Currency currency, uint256 originalAmount)
        public
        view
        returns (uint256 amount)
    {
        if (originalAmount > 0) {
            uint256 id = currency.toTokenId(poolId);
            amount = originalAmount.mulRatioX112(accruesRatioX112Of[id]);
        }
    }

    function getGrownRatioX112(uint256 id, uint256 growAmount) external view returns (uint256 accruesRatioX112Grown) {
        accruesRatioX112Grown = accruesRatioX112Of[id];
        if (growAmount > 1) {
            uint256 accruesRatioX112 = accruesRatioX112Grown;
            if (accruesRatioX112 > 0) {
                uint256 balance = balanceOriginal[address(this)][id];
                if (balance > growAmount) {
                    accruesRatioX112Grown = accruesRatioX112.growRatioX112(growAmount, balance);
                }
            }
        }
        if (accruesRatioX112Grown == 0) {
            accruesRatioX112Grown = UQ112x112.Q112;
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
        uint256 balance = balanceOriginal[address(this)][id];
        if (balance == 0) {
            if (interest > 0) {
                deviationOf[id] += interest;
            } else {
                revert InsufficientFunds();
            }
            return;
        }
        uint256 incrementRatioX112Old = accruesRatioX112Of[id];
        uint256 totalSupply = balance.mulRatioX112(incrementRatioX112Old);
        uint256 incrementRatioX112New;
        if (interest > 0) {
            incrementRatioX112New = incrementRatioX112Old.growRatioX112(uint256(interest), balance);
        } else {
            incrementRatioX112New = incrementRatioX112Old.reduceRatioX112(uint256(-interest), balance);
        }
        accruesRatioX112Of[id] = incrementRatioX112New;
        emit UpdateInterestRatio(id, totalSupply, interest, incrementRatioX112Old, incrementRatioX112New);
    }

    function updateProtocolInterests(PoolId poolId, Currency currency, uint256 interest)
        external
        onlyStatusManager
        returns (uint256 originalAmount)
    {
        if (interest == 0) {
            return originalAmount;
        }
        uint256 id = currency.toTokenId(poolId);
        mirrorTokenManager.mintInStatus(address(this), id, interest);
        originalAmount = _mint(owner, id, interest);
        emit Deposit(poolId, currency, msg.sender, owner, interest, originalAmount, accruesRatioX112Of[id]);
    }

    function sync(PoolId poolId, PoolStatus memory status) external onlyStatusManager {
        uint256 id = status.key.currency0.toTokenId(poolId);
        uint256 total = totalSupply(id);
        uint256 reserve = status.lendingReserve0();
        deviationOf[id] = reserve.toInt256() - total.toInt256();
        id = status.key.currency1.toTokenId(poolId);
        total = totalSupply(id);
        reserve = status.lendingReserve1();
        deviationOf[id] = reserve.toInt256() - total.toInt256();
    }

    function balanceAccounts(Currency currency, uint256 amount) external onlyPairManager {
        if (amount == 0) {
            return;
        }
        poolManager.transfer(msg.sender, currency.toId(), amount);
    }

    function mirrorIn(address receiver, PoolId poolId, Currency currency, uint256 amount)
        external
        onlyPairManager
        returns (uint256 originalAmount)
    {
        uint256 id = currency.toTokenId(poolId);
        mirrorTokenManager.transferFrom(msg.sender, address(this), id, amount);
        originalAmount = _mint(receiver, id, amount);
        emit Deposit(poolId, currency, msg.sender, receiver, amount, originalAmount, accruesRatioX112Of[id]);
    }

    function mirrorInRealOut(PoolId poolId, PoolStatus memory status, Currency currency, uint256 amount)
        external
        onlyPairManager
        returns (uint256 exchangeAmount)
    {
        uint256 id = currency.toId();
        uint256 balance;
        if (status.key.currency0 == currency) {
            balance = status.lendingRealReserve0;
        } else if (status.key.currency1 == currency) {
            balance = status.lendingRealReserve1;
        }
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
        originalAmount = _mint(recipient, id, amount);
        emit Deposit(poolId, currency, msg.sender, recipient, amount, originalAmount, accruesRatioX112Of[id]);
    }

    function reserveOut(address sender, PoolId poolId, PoolStatus memory status, Currency currency, uint256 amount)
        external
        onlyPairManager
    {
        uint256 tokenId = currency.toTokenId(poolId);
        uint256 balance = balanceOf(sender, tokenId);
        amount = Math.min(balance, amount);
        uint256 realReserve;
        if (status.key.currency0 == currency) {
            realReserve = status.lendingRealReserve0;
        } else if (status.key.currency1 == currency) {
            realReserve = status.lendingRealReserve1;
        }
        uint256 transferAmount = amount;
        if (transferAmount > realReserve) {
            poolManager.transfer(msg.sender, currency.toId(), realReserve);
            transferAmount -= realReserve;
        } else {
            poolManager.transfer(msg.sender, currency.toId(), transferAmount);
            transferAmount = 0;
        }
        if (transferAmount > 0) {
            mirrorTokenManager.transfer(msg.sender, tokenId, transferAmount);
        }
        uint256 originalAmount = _burn(sender, tokenId, amount);
        emit Withdraw(poolId, currency, msg.sender, sender, amount, originalAmount, accruesRatioX112Of[tokenId]);
    }

    // ******************** USER CALL ********************

    function _deposit(address sender, address recipient, PoolId poolId, Currency currency, uint256 amount)
        internal
        returns (uint256 originalAmount)
    {
        uint256 sendAmount = currency.checkAmount(amount);
        bytes memory result =
            poolManager.unlock(abi.encodeCall(this.handleDeposit, (sender, recipient, poolId, currency, amount)));
        originalAmount = abi.decode(result, (uint256));
        if (msg.value > sendAmount) transferNative(sender, msg.value - sendAmount);
    }

    function deposit(address sender, address recipient, PoolId poolId, Currency currency, uint256 amount)
        public
        payable
        onlyPositionManager
        returns (uint256 originalAmount)
    {
        originalAmount = _deposit(sender, recipient, poolId, currency, amount);
    }

    function deposit(address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        payable
        returns (uint256 originalAmount)
    {
        originalAmount = _deposit(msg.sender, recipient, poolId, currency, amount);
    }

    function handleDeposit(address sender, address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        selfOnly
        returns (uint256 originalAmount)
    {
        IPoolStatusManager statusManager = pairPoolManager.statusManager();
        statusManager.setBalances(poolId);
        uint256 id = currency.toTokenId(poolId);
        currency.settle(poolManager, sender, amount, false);
        currency.take(poolManager, address(this), amount, true);
        originalAmount = _mint(recipient, id, amount);
        emit Deposit(poolId, currency, sender, recipient, amount, originalAmount, accruesRatioX112Of[id]);
        statusManager.update(poolId);
    }

    function withdraw(address recipient, PoolId poolId, Currency currency, uint256 amount) external {
        poolManager.unlock(abi.encodeCall(this.handleWithdraw, (msg.sender, recipient, poolId, currency, amount)));
    }

    function handleWithdraw(address sender, address recipient, PoolId poolId, Currency currency, uint256 amount)
        external
        selfOnly
    {
        IPoolStatusManager statusManager = pairPoolManager.statusManager();
        PoolStatus memory status = statusManager.setBalances(poolId);
        uint256 id = currency.toTokenId(poolId);
        uint256 balance = balanceOf(sender, id);
        amount = Math.min(balance, amount);
        uint256 realReserve = currency == status.key.currency0 ? status.lendingRealReserve0 : status.lendingRealReserve1;
        uint256 realAmount = amount;
        if (realReserve < amount) {
            uint256 mirrorReserve =
                currency == status.key.currency0 ? status.lendingMirrorReserve0 : status.lendingMirrorReserve1;
            uint256 exchangeAmount = Math.min(amount - realReserve, mirrorReserve);
            bool success = pairPoolManager.mirrorInRealOut(poolId, status, currency, exchangeAmount);
            require(success, "NOT_ENOUGH_RESERVE");
            realAmount = realReserve + exchangeAmount;
        }
        currency.settle(poolManager, address(this), realAmount, true);
        currency.take(poolManager, recipient, realAmount, false);
        uint256 originalAmount = _burn(sender, id, realAmount);
        emit Withdraw(poolId, currency, sender, recipient, realAmount, originalAmount, accruesRatioX112Of[id]);
        statusManager.update(poolId);
    }

    function balanceMirror(PoolId poolId, Currency currency, uint256 amount) external payable {
        poolManager.unlock(abi.encodeCall(this.handleBalanceMirror, (msg.sender, poolId, currency, amount)));
    }

    function handleBalanceMirror(address sender, PoolId poolId, Currency currency, uint256 amount) external selfOnly {
        IPoolStatusManager statusManager = pairPoolManager.statusManager();
        statusManager.setBalances(poolId);
        uint256 id = currency.toTokenId(poolId);
        mirrorTokenManager.burn(id, amount);
        currency.settle(poolManager, sender, amount, false);
        currency.take(poolManager, address(this), amount, true);
        statusManager.update(poolId);
    }

    // ******************** OWNER CALL ********************

    function setPairPoolManger(IPairPoolManager _manager) external onlyOwner {
        pairPoolManager = _manager;
        mirrorTokenManager.setOperator(address(_manager), true);
    }
}
