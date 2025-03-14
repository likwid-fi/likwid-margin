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
import {TransientSlot} from "./external/openzeppelin-contracts/TransientSlot.sol";
import {CurrencyUtils} from "./libraries/CurrencyUtils.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {TimeUtils} from "./libraries/TimeUtils.sol";
import {LiquidityLevel} from "./libraries/LiquidityLevel.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {MarginPosition} from "./types/MarginPosition.sol";
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
import {IMarginOracleWriter} from "./interfaces/IMarginOracleWriter.sol";

contract PairPoolManager is IPairPoolManager, BaseFees, BasePoolManager {
    using TransientSlot for *;
    using UQ112x112 for *;
    using SafeCast for uint256;
    using TimeUtils for uint32;
    using LiquidityLevel for uint8;
    using FeeLibrary for uint24;
    using PerLibrary for uint256;
    using CurrencyUtils for Currency;

    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurnt();
    error NotPositionManager();

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

    IMirrorTokenManager public immutable mirrorTokenManager;
    ILendingPoolManager public immutable lendingPoolManager;
    IMarginLiquidity public immutable marginLiquidity;
    IHooks public hooks;
    IMarginFees public marginFees;
    IPoolStatusManager public statusManager;

    mapping(address => bool) private positionManagers;

    constructor(
        address initialOwner,
        IPoolManager _manager,
        IMirrorTokenManager _mirrorTokenManager,
        ILendingPoolManager _lendingPoolManager,
        IMarginLiquidity _marginLiquidity,
        IMarginFees _marginFees
    ) BasePoolManager(initialOwner, _manager) {
        mirrorTokenManager = _mirrorTokenManager;
        lendingPoolManager = _lendingPoolManager;
        marginLiquidity = _marginLiquidity;
        marginFees = _marginFees;
        mirrorTokenManager.setOperator(address(lendingPoolManager), true);
    }

    modifier onlyPosition() {
        if (!(positionManagers[msg.sender])) revert NotPositionManager();
        _;
    }

    modifier onlyFees() {
        require(msg.sender == address(marginFees), "UNAUTHORIZED");
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
        (amountIn,,) = marginFees.getAmountIn(status, zeroForOne, amountOut);
    }

    function getAmountOut(PoolId poolId, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
        PoolStatus memory status = statusManager.getStatus(poolId);
        (amountOut,,) = marginFees.getAmountOut(status, zeroForOne, amountIn);
    }

    // ******************** HOOK CALL ********************

    function initialize(PoolKey calldata key) external onlyHooks {
        statusManager.initialize(key);
        emit Initialize(key.toId(), key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
    }

    function setBalances(PoolKey calldata key) external onlyHooks {
        statusManager.setBalances(key);
    }

    function updateBalances(PoolKey calldata key) external onlyHooks {
        statusManager.update(key);
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
        PoolStatus memory _status = statusManager.getStatus(key.toId());
        bool exactInput = params.amountSpecified < 0;
        (specified, unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 feeAmount;
        if (exactInput) {
            (unspecifiedAmount, swapFee, feeAmount) =
                marginFees.getAmountOut(_status, params.zeroForOne, specifiedAmount);
            poolManager.approve(address(hooks), unspecified.toId(), unspecifiedAmount);
        } else {
            (unspecifiedAmount, swapFee, feeAmount) =
                marginFees.getAmountIn(_status, params.zeroForOne, specifiedAmount);
            poolManager.approve(address(hooks), specified.toId(), specifiedAmount);
        }
        if (feeAmount > 0) {
            feeAmount = statusManager.updateProtocolFees(specified, feeAmount);
            emit Fees(key.toId(), specified, sender, uint8(FeeType.SWAP), feeAmount);
        }
    }

    // ******************** SELF CALL ********************

    /// @inheritdoc IPairPoolManager
    function addLiquidity(AddLiquidityParams calldata params)
        external
        payable
        ensure(params.deadline)
        returns (uint256 liquidity)
    {
        require(params.amount0 > 0 && params.amount1 > 0, "AMOUNT_ERR");
        PoolStatus memory status = statusManager.getStatus(params.poolId);
        statusManager.setBalances(status.key);
        uint256 uPoolId = marginLiquidity.getPoolId(params.poolId);
        {
            uint256 _totalSupply = marginLiquidity.balanceOf(address(this), uPoolId);
            if (_totalSupply == 0) {
                liquidity = Math.sqrt(params.amount0 * params.amount1);
            } else {
                uint256 amount0In;
                uint256 amount1In;
                uint24 maxSliding = marginLiquidity.getMaxSliding();
                (liquidity, amount0In, amount1In) =
                    status.computeLiquidity(_totalSupply, params.amount0, params.amount1, maxSliding);
                if (params.amount0 > amount0In) {
                    status.key.currency0.transfer(msg.sender, params.amount0 - amount0In);
                }
                if (params.amount1 > amount1In) {
                    status.key.currency1.transfer(msg.sender, params.amount1 - amount1In);
                }
            }
            if (liquidity == 0) revert InsufficientLiquidityMinted();
        }
        liquidity = marginLiquidity.addLiquidity(params.to, uPoolId, params.level, liquidity);
        poolManager.unlock(
            abi.encodeCall(this.handleAddLiquidity, (msg.sender, status.key, params.amount0, params.amount1))
        );
        statusManager.update(status.key, false);
        emit Mint(params.poolId, msg.sender, params.to, liquidity, params.amount0, params.amount1, params.level);
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
        PoolStatus memory status = statusManager.getStatus(params.poolId);
        statusManager.setBalances(status.key);
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
                uint256 retainAmount0 = Math.mulDiv(retainSupply0, _reserve0, _totalSupply);
                if (maxReserve0 > retainAmount0) {
                    maxReserve0 -= retainAmount0;
                } else {
                    maxReserve0 = 0;
                }
            }
            // currency1 enable margin,can claim interest0
            if (params.level.oneForMargin()) {
                uint256 retainAmount1 = Math.mulDiv(retainSupply1, _reserve1, _totalSupply);
                if (maxReserve1 > retainAmount1) {
                    maxReserve1 -= retainAmount1;
                } else {
                    maxReserve1 = 0;
                }
            }
            require(amount0 <= maxReserve0 && amount1 <= maxReserve1, "NOT_ENOUGH_RESERVE");
            if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurnt();
        }

        poolManager.unlock(abi.encodeCall(this.handleRemoveLiquidity, (msg.sender, status.key, amount0, amount1)));
        statusManager.update(status.key);
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
        hooks = _hooks;
    }

    function setStatusManager(IPoolStatusManager _poolStatusManager) external onlyOwner {
        statusManager = _poolStatusManager;
    }

    function addPositionManager(address _marginPositionManager) external onlyOwner {
        positionManagers[_marginPositionManager] = true;
    }

    function setMarginFees(address _marginFees) external onlyOwner {
        marginFees = IMarginFees(_marginFees);
    }

    // ******************** MARGIN FUNCTIONS ********************

    /// @inheritdoc IPairPoolManager
    function margin(address sender, MarginParamsVo memory paramsVo)
        external
        payable
        onlyPosition
        returns (MarginParamsVo memory)
    {
        bytes memory result = poolManager.unlock(abi.encodeCall(this.handleMargin, (msg.sender, sender, paramsVo)));
        (paramsVo.params.marginAmount, paramsVo.marginTotal, paramsVo.params.borrowAmount) =
            abi.decode(result, (uint256, uint256, uint256));
        return paramsVo;
    }

    function handleMargin(address _positionManager, address sender, MarginParamsVo calldata paramsVo)
        external
        selfOnly
        returns (uint256 marginAmount, uint256 marginWithoutFee, uint256 borrowAmount)
    {
        MarginParams memory params = paramsVo.params;
        PoolStatus memory status = statusManager.getStatus(params.poolId);
        statusManager.setBalances(status.key);
        (Currency borrowCurrency, Currency marginCurrency) = params.marginForOne
            ? (status.key.currency0, status.key.currency1)
            : (status.key.currency1, status.key.currency0);
        uint256 marginFeeAmount;
        // transfer marginAmount to lendingPoolManager
        marginCurrency.settle(poolManager, sender, params.marginAmount, false);
        marginCurrency.take(poolManager, address(this), params.marginAmount, true);
        poolManager.approve(address(lendingPoolManager), marginCurrency.toId(), params.marginAmount);
        marginAmount = lendingPoolManager.realIn(_positionManager, params.poolId, marginCurrency, params.marginAmount);
        if (params.leverage > 0) {
            uint256 marginReserves;
            {
                (uint256 marginReserve0, uint256 marginReserve1) =
                    marginLiquidity.getFlowReserves(address(this), params.poolId, status);
                marginReserves = params.marginForOne ? marginReserve1 : marginReserve0;
            }
            uint256 marginTotal = params.marginAmount * params.leverage;
            require(marginReserves >= marginTotal, "TOKEN_NOT_ENOUGH");
            (borrowAmount,,) = marginFees.getAmountIn(status, params.marginForOne, marginTotal);
            (, uint24 marginFee) = marginFees.getPoolFees(address(this), params.poolId);
            (marginWithoutFee, marginFeeAmount) = marginFee.deduct(marginTotal);
            // transfer marginTotal to lendingPoolManager
            poolManager.approve(address(lendingPoolManager), marginCurrency.toId(), marginWithoutFee);
            marginWithoutFee =
                lendingPoolManager.realIn(_positionManager, params.poolId, marginCurrency, marginWithoutFee);
        } else {
            {
                uint256 actualAmount = params.marginAmount.mulMillionDiv(paramsVo.minMarginLevel);
                (uint256 reserve0, uint256 reserve1) = status.getReserves();
                (uint256 reserveBorrow, uint256 reserveMargin) =
                    params.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
                uint256 borrowMaxAmount = Math.mulDiv(actualAmount, reserveBorrow, reserveMargin);
                if (params.borrowAmount > 0) {
                    borrowAmount = Math.min(borrowMaxAmount, params.borrowAmount);
                } else {
                    borrowAmount = borrowMaxAmount;
                }
            }
            if (borrowAmount > 0) {
                // transfer borrowAmount to user
                borrowCurrency.settle(poolManager, address(this), borrowAmount, true);
                borrowCurrency.take(poolManager, params.recipient, borrowAmount, false);
            }
            marginWithoutFee = 0;
        }

        if (marginFeeAmount > 0) {
            uint256 feeAmount = statusManager.updateProtocolFees(marginCurrency, marginFeeAmount);
            emit Fees(params.poolId, marginCurrency, sender, uint8(FeeType.MARGIN), feeAmount);
        }

        // mint mirror token
        mirrorTokenManager.mint(borrowCurrency.toTokenId(params.poolId), borrowAmount);
        statusManager.update(status.key, true);
        {
            BalanceStatus memory balanceStatus = statusManager.setBalances(status.key);
            if (balanceStatus.mirrorBalance0 > 0) {
                lendingPoolManager.mirrorInRealOut(params.poolId, status.key.currency0, balanceStatus.mirrorBalance0);
            }
            if (balanceStatus.mirrorBalance1 > 0) {
                lendingPoolManager.mirrorInRealOut(params.poolId, status.key.currency1, balanceStatus.mirrorBalance1);
            }
            statusManager.update(status.key, false);
        }
    }

    /// @inheritdoc IPairPoolManager
    function release(ReleaseParams memory params) external payable onlyPosition returns (uint256) {
        bytes memory result = poolManager.unlock(abi.encodeCall(this.handleRelease, (params)));
        return abi.decode(result, (uint256));
    }

    function handleRelease(ReleaseParams calldata params) external selfOnly returns (uint256) {
        PoolStatus memory status = statusManager.getStatus(params.poolId);
        statusManager.updateInterests(status.key);
        statusManager.setBalances(status.key);
        (Currency borrowCurrency, Currency marginCurrency) = params.marginForOne
            ? (status.key.currency0, status.key.currency1)
            : (status.key.currency1, status.key.currency0);
        uint256 interest;
        if (params.releaseAmount > 0) {
            // release margin
            lendingPoolManager.realOut(params.payer, params.poolId, marginCurrency, params.releaseAmount);
            if (params.repayAmount > params.rawBorrowAmount) {
                uint256 overRepay = params.repayAmount - params.rawBorrowAmount;
                interest = Math.mulDiv(overRepay, params.releaseAmount, params.repayAmount);
            }
        } else if (params.repayAmount > 0) {
            // repay borrow
            borrowCurrency.settle(poolManager, params.payer, params.repayAmount, false);
            borrowCurrency.take(poolManager, address(this), params.repayAmount, true);
            if (params.repayAmount > params.rawBorrowAmount) {
                interest = params.repayAmount - params.rawBorrowAmount;
            }
        }
        // burn mirror token
        (uint256 pairAmount, uint256 lendingAmount) = mirrorTokenManager.burn(
            address(lendingPoolManager), borrowCurrency.toTokenId(params.poolId), params.repayAmount
        );
        if (params.repayAmount > pairAmount) {
            lendingAmount = Math.min(lendingAmount, params.repayAmount - pairAmount);
            poolManager.transfer(address(lendingPoolManager), borrowCurrency.toId(), lendingAmount);
        }
        if (interest > 0) {
            interest = statusManager.updateProtocolFees(borrowCurrency, interest);
        }
        statusManager.update(status.key, true);
        return params.repayAmount;
    }

    function mirrorInRealOut(PoolId poolId, Currency currency, uint256 amount)
        external
        onlyLendingPool
        returns (bool success)
    {
        uint256 id = currency.toId();
        uint256 balance = poolManager.balanceOf(address(this), id);
        if (balance > amount) {
            PoolStatus memory status = statusManager.getStatus(poolId);
            (uint256 marginReserve0, uint256 marginReserve1) =
                marginLiquidity.getFlowReserves(address(this), poolId, status);
            uint256 marginReserves = status.key.currency0 == currency ? marginReserve0 : marginReserve1;
            if (marginReserves >= amount) {
                statusManager.setBalances(status.key);
                poolManager.transfer(msg.sender, id, amount);
                mirrorTokenManager.transferFrom(msg.sender, address(this), currency.toTokenId(poolId), amount);
                statusManager.update(status.key);
                success = true;
            }
        }
    }

    function swapMirror(address sender, address recipient, PoolId poolId, bool zeroForOne, uint256 amountIn)
        external
        payable
        returns (uint256 amountOut)
    {
        PoolStatus memory status = statusManager.getStatus(poolId);
        uint256 feeAmount;
        (amountOut,, feeAmount) = marginFees.getAmountOut(status, zeroForOne, amountIn);
        uint256 mirrorOut = zeroForOne ? status.mirrorReserve1 : status.mirrorReserve0;
        require(amountOut <= mirrorOut, "NOT_ENOUGH_RESERVE");
        (Currency inputCurrency, Currency outputCurrency) =
            zeroForOne ? (status.key.currency0, status.key.currency1) : (status.key.currency1, status.key.currency0);
        uint256 sendValue = inputCurrency.checkAmount(amountIn);
        if (sendValue > 0) {
            amountIn = sendValue;
            if (msg.value > sendValue) {
                transferNative(sender, msg.value - sendValue);
            }
        }
        statusManager.setBalances(status.key);
        poolManager.unlock(abi.encodeCall(this.handleSwapMirror, (sender, inputCurrency, amountIn)));
        lendingPoolManager.mirrorIn(recipient, poolId, outputCurrency, amountOut);
        statusManager.update(status.key);
        if (feeAmount > 0) {
            feeAmount = statusManager.updateProtocolFees(inputCurrency, feeAmount);
            emit Fees(poolId, inputCurrency, sender, uint8(FeeType.SWAP), feeAmount);
        }
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
