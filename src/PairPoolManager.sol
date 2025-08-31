// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

// Openzeppelin
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Likwid V2 core
import {PoolKey} from "./types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "./types/PoolId.sol";
import {Currency, CurrencyLibrary} from "./types/Currency.sol";
import {IVault} from "./interfaces/IVault.sol";
// Local
import {BaseFees} from "./base/BaseFees.sol";
import {BasePoolManager} from "./base/BasePoolManager.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {CurrencyExtLibrary} from "./libraries/CurrencyExtLibrary.sol";
import {CurrencyPoolLibrary} from "./libraries/CurrencyPoolLibrary.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {TimeLibrary} from "./libraries/TimeLibrary.sol";
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
    using FeeLibrary for uint24;
    using PerLibrary for uint256;
    using CurrencyLibrary for Currency;
    using CurrencyExtLibrary for Currency;
    using CurrencyPoolLibrary for Currency;
    using PoolStatusLibrary for PoolStatus;

    error EmptyPool();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurnt();
    error InsufficientOutputReceived();
    error InsufficientValue();
    error NotPositionManager();
    error NotAllowed();
    error StatusManagerAlreadySet();
    error HookAlreadySet();
    error LowFeePoolMarginBanned();

    event Initialize(PoolId indexed id, Currency indexed currency0, Currency indexed currency1, uint24 fee);

    event Mint(
        PoolId indexed poolId,
        address indexed source,
        address indexed sender,
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event Burn(PoolId indexed poolId, address indexed sender, uint256 liquidity, uint256 amount0, uint256 amount1);

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
    IPoolStatusManager public statusManager;

    mapping(address => bool) public positionManagers;

    constructor(
        address initialOwner,
        IVault _manager,
        IMirrorTokenManager _mirrorTokenManager,
        ILendingPoolManager _lendingPoolManager,
        IMarginLiquidity _marginLiquidity
    ) BasePoolManager(initialOwner, _manager) {
        mirrorTokenManager = _mirrorTokenManager;
        lendingPoolManager = _lendingPoolManager;
        marginLiquidity = _marginLiquidity;
        vault.setOperator(address(lendingPoolManager), true);
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

    function initialize(PoolKey calldata key) external {
        statusManager.initialize(key);
        emit Initialize(key.toId(), key.currency0, key.currency1, key.fee);
    }

    function swap(address sender, PoolKey calldata key, IVault.SwapParams calldata params)
        external
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
            //vault.approve(address(hooks), unspecified.toId(), unspecifiedAmount);
        } else {
            (unspecifiedAmount, swapFee, feeAmount) =
                statusManager.getAmountIn(_status, params.zeroForOne, specifiedAmount);
            //vault.approve(address(hooks), specified.toId(), specifiedAmount);
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
        if (status.key.currency0.isAddressZero() && params.amount0 != msg.value) revert InsufficientValue();
        uint256 _totalSupply = marginLiquidity.getTotalSupply(params.poolId);
        uint256 amount0In;
        uint256 amount1In;
        (liquidity, amount0In, amount1In) =
            status.computeLiquidity(_totalSupply, params.amount0, params.amount1, params.amount0Min, params.amount1Min);
        if (params.amount0 > amount0In && status.key.currency0.isAddressZero()) {
            status.key.currency0.transfer(msg.sender, params.amount0 - amount0In);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        marginLiquidity.addLiquidity(msg.sender, params.poolId, liquidity);
        vault.unlock(abi.encodeCall(this.handleAddLiquidity, (msg.sender, status.key, amount0In, amount1In)));
        statusManager.update(params.poolId);
        emit Mint(params.poolId, params.source, msg.sender, liquidity, amount0In, amount1In);
    }

    /// @dev Handle liquidity addition by taking tokens from the sender and claiming ERC6909 to the hook address
    function handleAddLiquidity(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        selfOnly
    {
        key.currency0.settle(vault, sender, amount0, false);
        key.currency0.take(vault, address(this), amount0, true);
        key.currency1.settle(vault, sender, amount1, false);
        key.currency1.take(vault, address(this), amount1, true);
    }

    /// @inheritdoc IPairPoolManager
    function removeLiquidity(RemoveLiquidityParams memory params)
        external
        ensure(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        PoolStatus memory status = statusManager.setBalances(msg.sender, params.poolId);
        {
            (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
            uint256 _totalSupply;
            (_totalSupply, params.liquidity) =
                marginLiquidity.removeLiquidity(msg.sender, params.poolId, params.liquidity);
            amount0 = Math.mulDiv(params.liquidity, _reserve0, _totalSupply);
            amount1 = Math.mulDiv(params.liquidity, _reserve1, _totalSupply);
            require(amount0 <= status.realReserve0 && amount1 <= status.realReserve1, "NOT_ENOUGH_RESERVE");
            if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurnt();
            if (
                params.amount0Min > 0 && amount0 < params.amount0Min
                    || params.amount1Min > 0 && amount1 < params.amount1Min
            ) {
                revert InsufficientOutputReceived();
            }
        }

        vault.unlock(abi.encodeCall(this.handleRemoveLiquidity, (msg.sender, status.key, amount0, amount1)));
        statusManager.update(params.poolId);
        emit Burn(params.poolId, msg.sender, params.liquidity, amount0, amount1);
    }

    function handleRemoveLiquidity(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        selfOnly
    {
        // burn 6909s
        vault.burn(address(this), key.currency0.toId(), amount0);
        vault.burn(address(this), key.currency1.toId(), amount1);
        // transfer token to liquidity from address
        key.currency0.take(vault, sender, amount0, false);
        key.currency1.take(vault, sender, amount1, false);
    }

    // ******************** OWNER CALL ********************

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
        if (status.key.fee < 3000) revert LowFeePoolMarginBanned();
        bytes memory result = vault.unlock(abi.encodeCall(this.handleMargin, (msg.sender, sender, status, paramsVo)));
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
        marginCurrency.settle(vault, sender, params.marginAmount, false);
        marginCurrency.take(vault, address(this), params.marginAmount, true);

        if (params.leverage > 0) {
            uint256 marginReserves = params.marginForOne ? status.realReserve1 : status.realReserve0;
            uint256 marginTotal = params.marginAmount * params.leverage;
            require(marginReserves >= marginTotal, "MARGIN_NOT_ENOUGH");
            (borrowAmount,,) = statusManager.getAmountIn(status, params.marginForOne, marginTotal);
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
                    require(borrowMaxAmount >= params.borrowAmount, "BORROW_TOO_MUCH");
                    borrowAmount = params.borrowAmount;
                } else {
                    borrowAmount = borrowMaxAmount;
                }
                (uint256 flowReserve0, uint256 flowReserve1) = (status.reserve0(), status.reserve1());
                uint256 borrowReserves = (params.marginForOne ? flowReserve0 : flowReserve1);
                require(borrowReserves >= borrowAmount, "MIRROR_TOO_MUCH");
            }
            if (borrowAmount > 0) {
                // transfer borrowAmount to user
                borrowCurrency.settle(vault, address(this), borrowAmount, true);
                borrowCurrency.take(vault, sender, borrowAmount, false);
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
            int256 lendingInterest;
            uint256 diffUint = diff > 0 ? uint256(diff) : uint256(-diff);
            (uint256 interestReserve0, uint256 interestReserve1) = (status.reserve0(), status.reserve1());
            uint256 pairReserve = params.marginForOne ? interestReserve0 : interestReserve1;
            uint256 lendingReserve = params.marginForOne ? status.lendingReserve0() : status.lendingReserve1();
            uint256 lendingDiff = Math.mulDiv(diffUint, lendingReserve, pairReserve + lendingReserve);
            if (diff > 0) {
                lendingInterest = lendingDiff.toInt256();
            } else {
                lendingInterest = -(lendingDiff.toInt256());
            }
            if (lendingInterest != 0) {
                lendingPoolManager.updateInterests(borrowTokenId, lendingInterest);
                lendingInterest += lendingAmount.toInt256();
                if (lendingInterest > 0) {
                    vault.transfer(address(lendingPoolManager), borrowCurrency.toId(), uint256(lendingInterest));
                } else {
                    uint256 moveAmount = uint256(-lendingInterest);
                    if (moveAmount > 0) {
                        moveAmount = Math.min(moveAmount, lendingReserve);
                        uint256 lendingRealReserve =
                            params.marginForOne ? status.lendingRealReserve0 : status.lendingRealReserve1;
                        if (lendingRealReserve >= moveAmount) {
                            vault.transferFrom(
                                address(lendingPoolManager), address(this), borrowCurrency.toId(), moveAmount
                            );
                            moveAmount = 0;
                        } else {
                            vault.transferFrom(
                                address(lendingPoolManager), address(this), borrowCurrency.toId(), lendingRealReserve
                            );
                            moveAmount -= lendingRealReserve;
                        }
                        if (moveAmount > 0) {
                            mirrorTokenManager.transferFrom(
                                address(lendingPoolManager),
                                address(this),
                                borrowCurrency.toTokenId(status.key),
                                moveAmount
                            );
                        }
                    }
                }
            }
        } else {
            vault.transfer(address(lendingPoolManager), borrowCurrency.toId(), lendingAmount);
        }

        emit Release(params.poolId, borrowCurrency, params.debtAmount, repayAmount, burnAmount, params.rawBorrowAmount);
    }

    function release(address sender, PoolStatus memory status, ReleaseParams memory params)
        external
        payable
        onlyPosition
        returns (uint256)
    {
        bytes memory result = vault.unlock(abi.encodeCall(this.handleRelease, (sender, status, params)));
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
            borrowCurrency.settle(vault, params.payer, repayAmount, false);
            borrowCurrency.take(vault, address(this), repayAmount, true);
        }
        _releaseToPool(params, status, borrowCurrency, repayAmount);
        statusManager.update(params.poolId);
        return repayAmount;
    }

    // ******************** EXTERNAL FUNCTIONS ********************

    function mirrorInRealOut(PoolId poolId, Currency currency, uint256 amount)
        external
        onlyLendingPool
        returns (bool success)
    {
        uint256 id = currency.toId();
        uint256 balance = vault.balanceOf(address(this), id);
        if (balance > amount) {
            vault.transfer(msg.sender, id, amount);
            mirrorTokenManager.transferFrom(msg.sender, address(this), currency.toTokenId(poolId), amount);
            success = true;
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
        vault.unlock(abi.encodeCall(this.handleSwapMirror, (sender, inputCurrency, amountIn)));
        lendingPoolManager.mirrorIn(sender, recipient, poolId, outputCurrency, amountOut);
        if (feeAmount > 0) {
            feeAmount = statusManager.updateSwapProtocolFees(inputCurrency, feeAmount);
            emit Fees(poolId, inputCurrency, sender, uint8(FeeType.SWAP), feeAmount);
        }
        statusManager.update(poolId);
    }

    function handleSwapMirror(address sender, Currency currency, uint256 amount) external selfOnly {
        currency.settle(vault, sender, amount, false);
        currency.take(vault, address(this), amount, true);
    }

    /// @inheritdoc IPairPoolManager
    function collectProtocolFees(address recipient, Currency currency, uint256 amount)
        external
        onlyFees
        returns (uint256)
    {
        bytes memory result = vault.unlock(abi.encodeCall(this.handleCollectFees, (recipient, currency, amount)));
        return abi.decode(result, (uint256));
    }

    function handleCollectFees(address recipient, Currency currency, uint256 amount)
        external
        selfOnly
        returns (uint256 amountCollected)
    {
        amountCollected = statusManager.collectProtocolFees(currency, amount);
        currency.settle(vault, address(this), amountCollected, true);
        currency.take(vault, recipient, amountCollected, false);
    }
}
