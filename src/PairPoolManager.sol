// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// V4 core
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IPoolManager.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {BaseFees} from "./base/BaseFees.sol";
import {BasePoolManager} from "./base/BasePoolManager.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {CurrencyExtLibrary} from "./libraries/CurrencyExtLibrary.sol";
import {CurrencyPoolLibrary} from "./libraries/CurrencyPoolLibrary.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {TimeLibrary} from "./libraries/TimeLibrary.sol";
import {LiquidityLevel} from "./libraries/LiquidityLevel.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {MarginParams, MarginParamsVo} from "./types/MarginParams.sol";
import {ReleaseParams} from "./types/ReleaseParams.sol";
import {BalanceStatus} from "./types/BalanceStatus.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "./types/LiquidityParams.sol";

import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IPoolStatusManager} from "./interfaces/IPoolStatusManager.sol";
import {ILendingPoolManager} from "./interfaces/ILendingPoolManager.sol";
import {IMarginFees} from "./interfaces/IMarginFees.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";

contract PairPoolManager is IPairPoolManager, BaseFees, BasePoolManager {
    using UQ112x112 for *;
    using SafeCast for uint256;
    using TimeLibrary for uint32;
    using LiquidityLevel for uint8;
    using FeeLibrary for uint24;
    using PerLibrary for uint256;
    using CurrencyLibrary for Currency;
    using CurrencyExtLibrary for Currency;
    using CurrencyPoolLibrary for Currency;
    using PoolStatusLibrary for PoolStatus;

    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurnt();
    error InsufficientOutputReceived();
    error InsufficientValue();
    error NotPositionManager();
    error NotAllowed();
    error StatusManagerAlreadySet();
    error HookAlreadySet();
    error LowFeePoolOnlyOneLevel();

    event Initialize(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks
    );

    event Mint(
        PoolId indexed poolId,
        address indexed sender,
        address indexed to,
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint8 level
    );
    event Burn(
        PoolId indexed poolId, address indexed sender, uint256 liquidity, uint256 amount0, uint256 amount1, uint8 level
    );
    event Release(
        PoolId indexed poolId,
        Currency indexed borrowCurrency,
        uint256 debtAmount,
        uint256 repayAmount,
        uint256 burnAmount,
        uint256 rawBorrowAmount
    );

    event Swap(
        PoolId indexed poolId,
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        uint24 fee,
        bool zeroForOne,
        uint256 feeAmount
    );

    IMirrorTokenManager public immutable mirrorTokenManager;
    ILendingPoolManager public immutable lendingPoolManager;
    IMarginLiquidity public immutable marginLiquidity;
    IHooks public hooks;
    IPoolStatusManager public statusManager;

    mapping(address => bool) public positionManagers;

    constructor(
        address initialOwner,
        IPoolManager _manager,
        IMirrorTokenManager _mirrorTokenManager,
        ILendingPoolManager _lendingPoolManager,
        IMarginLiquidity _marginLiquidity
    ) BasePoolManager(initialOwner, _manager) {
        mirrorTokenManager = _mirrorTokenManager;
        lendingPoolManager = _lendingPoolManager;
        marginLiquidity = _marginLiquidity;
        poolManager.setOperator(address(lendingPoolManager), true);
        mirrorTokenManager.setOperator(address(lendingPoolManager), true);
    }

    function marginFees() public view returns (IMarginFees) {
        return statusManager.marginFees();
    }

    modifier onlyPosition() {
        if (!(positionManagers[msg.sender])) revert NotPositionManager();
        _;
    }

    modifier onlyFees() {
        require(msg.sender == address(marginFees()), "UNAUTHORIZED");
        _;
    }

    modifier onlyHooks() {
        require(msg.sender == address(hooks), "UNAUTHORIZED");
        _;
    }

    modifier onlyLendingPool() {
        require(msg.sender == address(lendingPoolManager), "UNAUTHORIZED");
        _;
    }

    function getStatus(PoolId poolId) external view returns (PoolStatus memory _status) {
        _status = statusManager.getStatus(poolId);
    }

    function getReserves(PoolId poolId) external view returns (uint256 _reserve0, uint256 _reserve1) {
        PoolStatus memory status = statusManager.getStatus(poolId);
        (_reserve0, _reserve1) = status.getReserves();
    }

    function getAmountIn(PoolId poolId, bool zeroForOne, uint256 amountOut) external view returns (uint256 amountIn) {
        PoolStatus memory status = statusManager.getStatus(poolId);
        (amountIn,,) = statusManager.getAmountIn(status, zeroForOne, amountOut);
    }

    function getAmountOut(PoolId poolId, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
        PoolStatus memory status = statusManager.getStatus(poolId);
        (amountOut,,) = statusManager.getAmountOut(status, zeroForOne, amountIn);
    }

    // ******************** HOOK CALL ********************

    function initialize(PoolKey calldata key) external onlyHooks {
        statusManager.initialize(key);
        emit Initialize(key.toId(), key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
    }

    function swap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        onlyHooks
        returns (
            Currency specified,
            Currency unspecified,
            uint256 specifiedAmount,
            uint256 unspecifiedAmount,
            uint24 swapFee
        )
    {
        PoolId poolId = key.toId();
        PoolStatus memory _status = statusManager.getStatus(poolId);
        bool exactInput = params.amountSpecified < 0;
        (specified, unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 feeAmount;
        if (exactInput) {
            (unspecifiedAmount, swapFee, feeAmount) =
                statusManager.getAmountOut(_status, params.zeroForOne, specifiedAmount);
            poolManager.approve(address(hooks), unspecified.toId(), unspecifiedAmount);
        } else {
            (unspecifiedAmount, swapFee, feeAmount) =
                statusManager.getAmountIn(_status, params.zeroForOne, specifiedAmount);
            poolManager.approve(address(hooks), specified.toId(), specifiedAmount);
        }
        if (feeAmount > 0) {
            Currency feeCurrency = params.zeroForOne ? key.currency0 : key.currency1;
            feeAmount = statusManager.updateSwapProtocolFees(feeCurrency, feeAmount);
            emit Fees(poolId, feeCurrency, sender, uint8(FeeType.SWAP), feeAmount);
        }
        (uint256 amount0, uint256 amount1) = (params.zeroForOne == exactInput)
            ? (specifiedAmount, unspecifiedAmount)
            : (unspecifiedAmount, specifiedAmount);
        emit Swap(poolId, sender, amount0, amount1, swapFee, params.zeroForOne, feeAmount);
    }

    // ******************** SELF CALL ********************

    /// @inheritdoc IPairPoolManager
    function addLiquidity(AddLiquidityParams calldata params)
        external
        payable
        ensure(params.deadline)
        returns (uint256 liquidity)
    {
        PoolStatus memory status = statusManager.setBalances(msg.sender, params.poolId);
        if (params.level > LiquidityLevel.RETAIN_BOTH && status.key.fee < 3000) revert LowFeePoolOnlyOneLevel();
        if (status.key.currency0.isAddressZero() && params.amount0 != msg.value) revert InsufficientValue();
        uint256 uPoolId = marginLiquidity.getPoolId(params.poolId);
        uint256 _totalSupply = marginLiquidity.balanceOf(address(this), uPoolId);
        uint256 amount0In;
        uint256 amount1In;
        (liquidity, amount0In, amount1In) =
            status.computeLiquidity(_totalSupply, params.amount0, params.amount1, params.amount0Min, params.amount1Min);
        if (params.amount0 > amount0In && status.key.currency0.isAddressZero()) {
            status.key.currency0.transfer(msg.sender, params.amount0 - amount0In);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        marginLiquidity.addLiquidity(msg.sender, params.to, uPoolId, params.level, liquidity);
        poolManager.unlock(abi.encodeCall(this.handleAddLiquidity, (msg.sender, status.key, amount0In, amount1In)));
        statusManager.update(params.poolId);
        emit Mint(params.poolId, msg.sender, params.to, liquidity, amount0In, amount1In, params.level);
    }

    /// @dev Handle liquidity addition by taking tokens from the sender and claiming ERC6909 to the hook address
    function handleAddLiquidity(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        selfOnly
    {
        key.currency0.settle(poolManager, sender, amount0, false);
        key.currency0.take(poolManager, address(this), amount0, true);
        key.currency1.settle(poolManager, sender, amount1, false);
        key.currency1.take(poolManager, address(this), amount1, true);
    }

    /// @inheritdoc IPairPoolManager
    function removeLiquidity(RemoveLiquidityParams memory params)
        external
        ensure(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        PoolStatus memory status = statusManager.setBalances(msg.sender, params.poolId);
        uint256 uPoolId = marginLiquidity.getPoolId(params.poolId);
        {
            (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
            (uint256 _totalSupply, uint256 retainSupply0, uint256 retainSupply1) = marginLiquidity.getSupplies(uPoolId);
            params.liquidity = marginLiquidity.removeLiquidity(msg.sender, uPoolId, params.level, params.liquidity);
            uint256 maxReserve0 = status.realReserve0;
            uint256 maxReserve1 = status.realReserve1;
            amount0 = Math.mulDiv(params.liquidity, _reserve0, _totalSupply);
            amount1 = Math.mulDiv(params.liquidity, _reserve1, _totalSupply);
            // currency0 enable margin,can claim interest1
            if (params.level.zeroForMargin()) {
                uint256 retainAmount1 = Math.mulDiv(retainSupply1, _reserve1, _totalSupply);
                if (maxReserve1 > retainAmount1) {
                    maxReserve1 -= retainAmount1;
                } else {
                    maxReserve1 = 0;
                }
            }
            // currency1 enable margin,can claim interest0
            if (params.level.oneForMargin()) {
                uint256 retainAmount0 = Math.mulDiv(retainSupply0, _reserve0, _totalSupply);
                if (maxReserve0 > retainAmount0) {
                    maxReserve0 -= retainAmount0;
                } else {
                    maxReserve0 = 0;
                }
            }
            require(amount0 <= maxReserve0 && amount1 <= maxReserve1, "NOT_ENOUGH_RESERVE");
            if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurnt();
            if (
                params.amount0Min > 0 && amount0 < params.amount0Min
                    || params.amount1Min > 0 && amount1 < params.amount1Min
            ) {
                revert InsufficientOutputReceived();
            }
        }

        poolManager.unlock(abi.encodeCall(this.handleRemoveLiquidity, (msg.sender, status.key, amount0, amount1)));
        statusManager.update(params.poolId);
        emit Burn(params.poolId, msg.sender, params.liquidity, amount0, amount1, params.level);
    }

    function handleRemoveLiquidity(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        selfOnly
    {
        // burn 6909s
        poolManager.burn(address(this), key.currency0.toId(), amount0);
        poolManager.burn(address(this), key.currency1.toId(), amount1);
        // transfer token to liquidity from address
        key.currency0.take(poolManager, sender, amount0, false);
        key.currency1.take(poolManager, sender, amount1, false);
    }

    // ******************** OWNER CALL ********************
    function setHooks(IHooks _hooks) external onlyOwner {
        if (address(hooks) != address(0)) revert HookAlreadySet();
        hooks = _hooks;
    }

    function setStatusManager(IPoolStatusManager _poolStatusManager) external onlyOwner {
        if (address(statusManager) != address(0)) revert StatusManagerAlreadySet();
        statusManager = _poolStatusManager;
    }

    function addPositionManager(address _marginPositionManager) external onlyOwner {
        positionManagers[_marginPositionManager] = true;
    }

    function removePositionManager(address _marginPositionManager) external onlyOwner {
        delete positionManagers[_marginPositionManager];
    }

    // ******************** MARGIN FUNCTIONS ********************

    function setBalances(address sender, PoolId poolId) external onlyPosition returns (PoolStatus memory _status) {
        _status = statusManager.setBalances(sender, poolId);
    }

    function margin(address sender, PoolStatus memory status, MarginParamsVo memory paramsVo)
        external
        payable
        onlyPosition
        returns (MarginParamsVo memory)
    {
        bytes memory result =
            poolManager.unlock(abi.encodeCall(this.handleMargin, (msg.sender, sender, status, paramsVo)));
        (paramsVo.params.marginAmount, paramsVo.marginTotal, paramsVo.params.borrowAmount) =
            abi.decode(result, (uint256, uint256, uint256));
        return paramsVo;
    }

    function handleMargin(
        address _positionManager,
        address sender,
        PoolStatus memory status,
        MarginParamsVo calldata paramsVo
    ) external selfOnly returns (uint256 marginAmount, uint256 marginWithoutFee, uint256 borrowAmount) {
        MarginParams memory params = paramsVo.params;
        (Currency borrowCurrency, Currency marginCurrency) = params.marginForOne
            ? (status.key.currency0, status.key.currency1)
            : (status.key.currency1, status.key.currency0);
        uint256 marginFeeAmount;
        // transfer marginAmount to lendingPoolManager
        marginCurrency.settle(poolManager, sender, params.marginAmount, false);
        marginCurrency.take(poolManager, address(this), params.marginAmount, true);

        if (params.leverage > 0) {
            (uint256 marginReserve0, uint256 marginReserve1, uint256 incrementMaxMirror0, uint256 incrementMaxMirror1) =
                marginLiquidity.getMarginReserves(address(this), params.poolId, status);
            uint256 marginReserves = params.marginForOne ? marginReserve1 : marginReserve0;
            uint256 incrementMaxMirror = params.marginForOne ? incrementMaxMirror0 : incrementMaxMirror1;

            uint256 marginTotal = params.marginAmount * params.leverage;
            require(marginReserves >= marginTotal, "MARGIN_NOT_ENOUGH");
            (borrowAmount,,) = statusManager.getAmountIn(status, params.marginForOne, marginTotal);
            require(incrementMaxMirror >= borrowAmount, "MIRROR_TOO_MUCH");

            uint24 _marginFeeRate = status.marginFee == 0 ? statusManager.marginFees().marginFee() : status.marginFee;
            (marginWithoutFee, marginFeeAmount) = _marginFeeRate.deduct(marginTotal);
            // transfer marginTotal to lendingPoolManager
            marginWithoutFee =
                lendingPoolManager.realIn(sender, _positionManager, params.poolId, marginCurrency, marginWithoutFee);
        } else {
            {
                uint256 borrowMaxAmount = status.getAmountOut(!params.marginForOne, params.marginAmount);
                uint256 flowMaxAmount = (params.marginForOne ? status.realReserve0 : status.realReserve1) * 20 / 100;
                borrowMaxAmount = borrowMaxAmount.mulMillionDiv(paramsVo.minMarginLevel);
                borrowMaxAmount = Math.min(borrowMaxAmount, flowMaxAmount);

                if (params.borrowAmount > 0) {
                    borrowAmount = Math.min(borrowMaxAmount, params.borrowAmount);
                } else {
                    borrowAmount = borrowMaxAmount;
                }
                (uint256 flowReserve0, uint256 flowReserve1) =
                    marginLiquidity.getFlowReserves(address(this), params.poolId, status);
                uint256 borrowReserves = (params.marginForOne ? flowReserve0 : flowReserve1);
                require(borrowReserves >= borrowAmount, "MIRROR_TOO_MUCH");
            }
            if (borrowAmount > 0) {
                // transfer borrowAmount to user
                borrowCurrency.settle(poolManager, address(this), borrowAmount, true);
                borrowCurrency.take(poolManager, sender, borrowAmount, false);
            }
            marginWithoutFee = 0;
        }

        if (marginFeeAmount > 0) {
            uint256 feeAmount = statusManager.updateMarginProtocolFees(marginCurrency, marginFeeAmount);
            emit Fees(params.poolId, marginCurrency, sender, uint8(FeeType.MARGIN), feeAmount);
        }
        marginAmount =
            lendingPoolManager.realIn(sender, _positionManager, params.poolId, marginCurrency, params.marginAmount);
        // mint mirror token
        mirrorTokenManager.mint(borrowCurrency.toTokenId(params.poolId), borrowAmount);
        (uint256 mirrorBalance0, uint256 mirrorBalance1) = borrowCurrency == status.key.currency0
            ? (borrowAmount + status.mirrorReserve0, uint256(status.mirrorReserve1))
            : (uint256(status.mirrorReserve0), borrowAmount + status.mirrorReserve1);
        if (mirrorBalance0 > 0) {
            lendingPoolManager.mirrorInRealOut(params.poolId, status, status.key.currency0, mirrorBalance0);
        }
        if (mirrorBalance1 > 0) {
            lendingPoolManager.mirrorInRealOut(params.poolId, status, status.key.currency1, mirrorBalance1);
        }
        statusManager.update(params.poolId);
    }

    function _releaseToPool(
        ReleaseParams calldata params,
        PoolStatus memory status,
        Currency borrowCurrency,
        uint256 repayAmount
    ) internal {
        uint256 borrowTokenId = borrowCurrency.toTokenId(params.poolId);
        // burn mirror token
        (uint256 pairAmount, uint256 lendingAmount) =
            mirrorTokenManager.burn(address(lendingPoolManager), borrowTokenId, params.debtAmount);
        uint256 burnAmount = pairAmount + lendingAmount;
        int256 diff = repayAmount.toInt256() - params.debtAmount.toInt256();
        if (diff != 0) {
            int256 interest0;
            int256 interest1;
            int256 lendingInterest;
            uint256 diffUint = diff > 0 ? uint256(diff) : uint256(-diff);
            (uint256 interestReserve0, uint256 interestReserve1) =
                marginLiquidity.getInterestReserves(address(this), params.poolId, status);
            uint256 pairReserve = params.marginForOne ? interestReserve0 : interestReserve1;
            uint256 lendingReserve = params.marginForOne ? status.lendingReserve0() : status.lendingReserve1();
            uint256 lendingDiff = Math.mulDiv(diffUint, lendingReserve, pairReserve + lendingReserve);
            uint256 pairDiff = diffUint - lendingDiff;
            if (diff > 0) {
                if (params.marginForOne) {
                    interest0 = pairDiff.toInt256();
                } else {
                    interest1 = pairDiff.toInt256();
                }
                lendingInterest = lendingDiff.toInt256();
            } else {
                if (params.marginForOne) {
                    interest0 = -(pairDiff.toInt256());
                } else {
                    interest1 = -(pairDiff.toInt256());
                }
                lendingInterest = -(lendingDiff.toInt256());
            }
            if (interest0 != 0 || interest1 != 0) {
                marginLiquidity.changeLiquidity(
                    params.poolId, status.reserve0(), status.reserve1(), interest0, interest1
                );
            }
            if (lendingInterest != 0) {
                lendingPoolManager.updateInterests(borrowTokenId, lendingInterest);
                lendingInterest += lendingAmount.toInt256();
                if (lendingInterest > 0) {
                    poolManager.transfer(address(lendingPoolManager), borrowCurrency.toId(), uint256(lendingInterest));
                } else {
                    lendingPoolManager.balanceAccounts(borrowCurrency, uint256(-lendingInterest));
                }
            }
        } else {
            poolManager.transfer(address(lendingPoolManager), borrowCurrency.toId(), lendingAmount);
        }

        emit Release(params.poolId, borrowCurrency, params.debtAmount, repayAmount, burnAmount, params.rawBorrowAmount);
    }

    function release(address sender, PoolStatus memory status, ReleaseParams memory params)
        external
        payable
        onlyPosition
        returns (uint256)
    {
        bytes memory result = poolManager.unlock(abi.encodeCall(this.handleRelease, (sender, status, params)));
        return abi.decode(result, (uint256));
    }

    function handleRelease(address sender, PoolStatus memory status, ReleaseParams calldata params)
        external
        selfOnly
        returns (uint256)
    {
        (Currency borrowCurrency, Currency marginCurrency) = params.marginForOne
            ? (status.key.currency0, status.key.currency1)
            : (status.key.currency1, status.key.currency0);
        // take repayAmount borrowCurrency from the pool
        uint256 repayAmount = params.repayAmount;
        if (params.releaseAmount > 0) {
            if (repayAmount == 0) {
                // when liquidated
                repayAmount = status.getAmountOut(!params.marginForOne, params.releaseAmount);
            }

            // release margin
            lendingPoolManager.reserveOut(
                sender, params.payer, params.poolId, status, marginCurrency, params.releaseAmount + 1
            );
        } else if (repayAmount > 0) {
            // repay borrow
            borrowCurrency.settle(poolManager, params.payer, repayAmount, false);
            borrowCurrency.take(poolManager, address(this), repayAmount, true);
        }
        _releaseToPool(params, status, borrowCurrency, repayAmount);
        statusManager.update(params.poolId);
        return repayAmount;
    }

    // ******************** EXTERNAL FUNCTIONS ********************

    function mirrorInRealOut(PoolId poolId, PoolStatus memory status, Currency currency, uint256 amount)
        external
        onlyLendingPool
        returns (bool success)
    {
        uint256 id = currency.toId();
        uint256 balance = poolManager.balanceOf(address(this), id);
        if (balance > amount) {
            (,, uint256 incrementMaxMirror0, uint256 incrementMaxMirror1) =
                marginLiquidity.getMarginReserves(address(this), poolId, status);
            uint256 incrementMaxMirror = status.key.currency0 == currency ? incrementMaxMirror0 : incrementMaxMirror1;
            if (incrementMaxMirror >= amount) {
                poolManager.transfer(msg.sender, id, amount);
                mirrorTokenManager.transferFrom(msg.sender, address(this), currency.toTokenId(poolId), amount);
                success = true;
            }
        }
    }

    function swapMirror(address recipient, PoolId poolId, bool zeroForOne, uint256 amountIn, uint256 amountOutMin)
        external
        payable
        returns (uint256 amountOut)
    {
        address sender = msg.sender;
        PoolStatus memory status = statusManager.setBalances(sender, poolId);
        uint256 feeAmount;
        (amountOut,, feeAmount) = statusManager.getAmountOut(status, zeroForOne, amountIn);
        uint256 mirrorOut = zeroForOne ? status.mirrorReserve1 : status.mirrorReserve0;
        require(amountOut <= mirrorOut, "NOT_ENOUGH_RESERVE");
        if (amountOutMin > 0 && amountOut < amountOutMin) revert InsufficientOutputReceived();
        (Currency inputCurrency, Currency outputCurrency) =
            zeroForOne ? (status.key.currency0, status.key.currency1) : (status.key.currency1, status.key.currency0);
        uint256 sendValue = inputCurrency.checkAmount(amountIn);
        if (sendValue > 0) {
            amountIn = sendValue;
            if (msg.value > sendValue) {
                transferNative(sender, msg.value - sendValue);
            }
        }
        poolManager.unlock(abi.encodeCall(this.handleSwapMirror, (sender, inputCurrency, amountIn)));
        lendingPoolManager.mirrorIn(sender, recipient, poolId, outputCurrency, amountOut);
        if (feeAmount > 0) {
            feeAmount = statusManager.updateSwapProtocolFees(inputCurrency, feeAmount);
            emit Fees(poolId, inputCurrency, sender, uint8(FeeType.SWAP), feeAmount);
        }
        statusManager.update(poolId);
    }

    function handleSwapMirror(address sender, Currency currency, uint256 amount) external selfOnly {
        currency.settle(poolManager, sender, amount, false);
        currency.take(poolManager, address(this), amount, true);
    }

    /// @inheritdoc IPairPoolManager
    function collectProtocolFees(address recipient, Currency currency, uint256 amount)
        external
        onlyFees
        returns (uint256)
    {
        bytes memory result = poolManager.unlock(abi.encodeCall(this.handleCollectFees, (recipient, currency, amount)));
        return abi.decode(result, (uint256));
    }

    function handleCollectFees(address recipient, Currency currency, uint256 amount)
        external
        selfOnly
        returns (uint256 amountCollected)
    {
        amountCollected = statusManager.collectProtocolFees(currency, amount);
        currency.settle(poolManager, address(this), amountCollected, true);
        currency.take(poolManager, recipient, amountCollected, false);
    }
}
