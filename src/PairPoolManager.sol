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
import {BasePool} from "./base/BasePool.sol";
import {TransientSlot} from "./external/openzeppelin-contracts/TransientSlot.sol";
import {ReentrancyGuardTransient} from "./external/openzeppelin-contracts/ReentrancyGuardTransient.sol";
import {CurrencyUtils} from "./libraries/CurrencyUtils.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {TimeUtils} from "./libraries/TimeUtils.sol";
import {LiquidityLevel} from "./libraries/LiquidityLevel.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {MarginPosition} from "./types/MarginPosition.sol";
import {MarginParams} from "./types/MarginParams.sol";
import {ReleaseParams} from "./types/ReleaseParams.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {BalanceStatus} from "./types/BalanceStatus.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "./types/LiquidityParams.sol";

import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {ILendingPoolManager} from "./interfaces/ILendingPoolManager.sol";
import {IMarginFees} from "./interfaces/IMarginFees.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";
import {IMarginOracleWriter} from "./interfaces/IMarginOracleWriter.sol";

contract PairPoolManager is IPairPoolManager, BasePool, ReentrancyGuardTransient {
    using TransientSlot for *;
    using UQ112x112 for *;
    using SafeCast for uint256;
    using TimeUtils for uint32;
    using LiquidityLevel for uint8;
    using FeeLibrary for uint24;
    using PerLibrary for uint256;
    using CurrencyUtils for Currency;

    error UpdateBalanceGuardErrorCall();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurnt();
    error NotPositionManager();
    error PairAlreadyExists();
    error PairNotExists();

    event Mint(
        PoolId indexed poolId,
        address indexed sender,
        address indexed to,
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event Burn(PoolId indexed poolId, address indexed sender, uint256 liquidity, uint256 amount0, uint256 amount1);
    event Sync(
        PoolId indexed poolId,
        uint256 realReserve0,
        uint256 realReserve1,
        uint256 mirrorReserve0,
        uint256 mirrorReserve1
    );

    bytes32 constant UPDATE_BALANCE_GUARD_SLOT = 0x885c9ad615c28a45189565668235695fb42940589d40d91c5c875c16cdc1bd4c;
    bytes32 constant BALANCE_0_SLOT = 0x608a02038d3023ed7e79ffc2a87ce7ad8c0bc0c5b839ddbe438db934c7b5e0e2;
    bytes32 constant BALANCE_1_SLOT = 0xba598ef587ec4c4cf493fe15321596d40159e5c3c0cbf449810c8c6894b2e5e1;
    bytes32 constant MIRROR_BALANCE_0_SLOT = 0x63450183817719ccac1ebea450ccc19412314611d078d8a8cb3ac9a1ef4de386;
    bytes32 constant MIRROR_BALANCE_1_SLOT = 0xbdb25f21ec501c2e41736c4e3dd44c1c3781af532b6899c36b3f72d4e003b0ab;

    IMirrorTokenManager public immutable mirrorTokenManager;
    ILendingPoolManager public immutable lendingPoolManager;
    IMarginLiquidity public immutable marginLiquidity;
    IHooks public hooks;
    IMarginFees public marginFees;
    address public marginOracle;

    mapping(PoolId => PoolStatus) private statusStore;
    mapping(address => bool) private positionManagers;
    mapping(Currency currency => uint256 amount) public protocolFeesAccrued;

    constructor(
        address initialOwner,
        IPoolManager _manager,
        IMirrorTokenManager _mirrorTokenManager,
        ILendingPoolManager _lendingPoolManager,
        IMarginLiquidity _marginLiquidity,
        IMarginFees _marginFees
    ) BasePool(initialOwner, _manager) {
        mirrorTokenManager = _mirrorTokenManager;
        lendingPoolManager = _lendingPoolManager;
        marginLiquidity = _marginLiquidity;
        marginFees = _marginFees;
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    modifier onlyPosition() {
        if (!(positionManagers[msg.sender])) revert NotPositionManager();
        _;
    }

    modifier onlyFees() {
        if (address(marginFees) != msg.sender) revert NotPositionManager();
        _;
    }

    modifier onlyHooks() {
        require(msg.sender == address(msg.sender), "UNAUTHORIZED");
        _;
    }

    function getStatus(PoolId poolId) public view returns (PoolStatus memory _status) {
        _status = statusStore[poolId];
        if (_status.key.currency1 == CurrencyLibrary.ADDRESS_ZERO) revert PairNotExists();
        (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) = marginFees.getBorrowRateCumulativeLast(_status);
        _status.mirrorReserve0 =
            uint112(Math.mulDiv(_status.mirrorReserve0, rate0CumulativeLast, _status.rate0CumulativeLast));
        _status.mirrorReserve1 =
            uint112(Math.mulDiv(_status.mirrorReserve1, rate1CumulativeLast, _status.rate1CumulativeLast));
        _status.blockTimestampLast = uint32(block.timestamp % 2 ** 32);
        _status.rate0CumulativeLast = rate0CumulativeLast;
        _status.rate1CumulativeLast = rate1CumulativeLast;
    }

    function getReserves(PoolId poolId) external view returns (uint256 _reserve0, uint256 _reserve1) {
        PoolStatus memory status = getStatus(poolId);
        (_reserve0, _reserve1) = status.getReserves();
    }

    function getAmountIn(PoolId poolId, bool zeroForOne, uint256 amountOut) external view returns (uint256 amountIn) {
        PoolStatus memory status = getStatus(poolId);
        (amountIn,,) = _getAmountIn(status, zeroForOne, amountOut);
    }

    function getAmountOut(PoolId poolId, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
        PoolStatus memory status = getStatus(poolId);
        (amountOut,,) = _getAmountOut(status, zeroForOne, amountIn);
    }

    // ******************** INTERNAL FUNCTIONS ********************

    function _callSet() internal {
        if (_notCallUpdate()) {
            revert UpdateBalanceGuardErrorCall();
        }

        UPDATE_BALANCE_GUARD_SLOT.asBoolean().tstore(true);
    }

    function _callUpdate() internal {
        UPDATE_BALANCE_GUARD_SLOT.asBoolean().tstore(false);
    }

    function _notCallUpdate() internal view returns (bool) {
        return UPDATE_BALANCE_GUARD_SLOT.asBoolean().tload();
    }

    function _getBalances() internal view returns (BalanceStatus memory) {
        uint256 balance0 = BALANCE_0_SLOT.asUint256().tload();
        uint256 balance1 = BALANCE_1_SLOT.asUint256().tload();
        uint256 mirrorBalance0 = MIRROR_BALANCE_0_SLOT.asUint256().tload();
        uint256 mirrorBalance1 = MIRROR_BALANCE_1_SLOT.asUint256().tload();
        return BalanceStatus(balance0, balance1, mirrorBalance0, mirrorBalance1);
    }

    function _getBalances(PoolKey memory key) internal view returns (BalanceStatus memory balanceStatus) {
        uint256 protocolFees0 = protocolFeesAccrued[key.currency0];
        uint256 protocolFees1 = protocolFeesAccrued[key.currency1];
        balanceStatus.balance0 = poolManager.balanceOf(address(this), key.currency0.toId());
        if (balanceStatus.balance0 > protocolFees0) {
            balanceStatus.balance0 -= protocolFees0;
        } else {
            balanceStatus.balance0 = 0;
        }
        balanceStatus.balance1 = poolManager.balanceOf(address(this), key.currency1.toId());
        if (balanceStatus.balance1 > protocolFees1) {
            balanceStatus.balance1 -= protocolFees1;
        } else {
            balanceStatus.balance1 = 0;
        }
        balanceStatus.mirrorBalance0 = mirrorTokenManager.balanceOf(address(this), key.currency0.toKeyId(key));
        balanceStatus.mirrorBalance1 = mirrorTokenManager.balanceOf(address(this), key.currency1.toKeyId(key));
    }

    function _setBalances(PoolKey memory key) internal returns (BalanceStatus memory balanceStatus) {
        _callSet();
        balanceStatus = _getBalances(key);
        BALANCE_0_SLOT.asUint256().tstore(balanceStatus.balance0);
        BALANCE_1_SLOT.asUint256().tstore(balanceStatus.balance1);
        MIRROR_BALANCE_0_SLOT.asUint256().tstore(balanceStatus.mirrorBalance0);
        MIRROR_BALANCE_1_SLOT.asUint256().tstore(balanceStatus.mirrorBalance1);
    }

    function _updateInterests(PoolStatus storage status, bool inUpdate) internal {
        PoolKey memory key = status.key;
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        if (status.blockTimestampLast != blockTS) {
            (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) = marginFees.getBorrowRateCumulativeLast(status);
            uint256 interest0;
            uint256 interest1;
            if (status.mirrorReserve0 > 0 && rate0CumulativeLast > status.rate0CumulativeLast) {
                interest0 = Math.mulDiv(status.mirrorReserve0, rate0CumulativeLast, status.rate0CumulativeLast)
                    - status.mirrorReserve0;
                if (!inUpdate) {
                    status.mirrorReserve0 += uint112(interest0);
                }
                mirrorTokenManager.mint(key.currency0.toKeyId(key), interest0);
            }
            if (status.mirrorReserve1 > 0 && rate1CumulativeLast > status.rate1CumulativeLast) {
                interest1 = Math.mulDiv(status.mirrorReserve1, rate1CumulativeLast, status.rate1CumulativeLast)
                    - status.mirrorReserve1;
                if (!inUpdate) {
                    status.mirrorReserve1 += uint112(interest1);
                }
                mirrorTokenManager.mint(key.currency1.toKeyId(key), interest1);
            }
            status.blockTimestampLast = blockTS;
            status.rate0CumulativeLast = rate0CumulativeLast;
            status.rate1CumulativeLast = rate1CumulativeLast;
            marginLiquidity.addInterests(key.toId(), status.reserve0(), status.reserve1(), interest0, interest1);
        }
    }

    function _updateInterests(PoolKey memory key) internal {
        PoolId pooId = key.toId();
        PoolStatus storage status = statusStore[pooId];
        _updateInterests(status, false);
    }

    function _update(PoolKey memory key, bool fromMargin) internal {
        PoolId pooId = key.toId();
        PoolStatus storage status = statusStore[pooId];
        // save margin price before changed
        if (fromMargin) {
            uint32 blockTS = uint32(block.timestamp % 2 ** 32);
            if (status.marginTimestampLast != blockTS) {
                status.marginTimestampLast = blockTS;
                status.lastPrice1X112 = status.getPrice1X112();
            }
            if (status.lastPrice1X112 == 0) status.lastPrice1X112 = status.getPrice1X112();
        }

        BalanceStatus memory beforeStatus = _getBalances();
        _updateInterests(status, true);
        BalanceStatus memory afterStatus = _getBalances(key);

        status.realReserve0 = status.realReserve0.add(afterStatus.balance0).sub(beforeStatus.balance0);
        status.realReserve1 = status.realReserve1.add(afterStatus.balance1).sub(beforeStatus.balance1);
        status.mirrorReserve0 = status.mirrorReserve0.add(afterStatus.mirrorBalance0).sub(beforeStatus.mirrorBalance0);
        status.mirrorReserve1 = status.mirrorReserve1.add(afterStatus.mirrorBalance1).sub(beforeStatus.mirrorBalance1);

        uint112 _reserve0 = status.reserve0();
        uint112 _reserve1 = status.reserve1();
        if (marginOracle != address(0)) {
            IMarginOracleWriter(marginOracle).write(status.key, _reserve0, _reserve1);
        }

        emit Sync(pooId, status.realReserve0, status.realReserve1, status.mirrorReserve0, status.mirrorReserve1);
        _callUpdate();
    }

    function _update(PoolKey memory key) internal {
        _update(key, false);
    }

    function _updateProtocolFees(Currency currency, uint256 amount) internal returns (uint256 restAmount) {
        unchecked {
            uint256 protocolFees = marginFees.getProtocolFeeAmount(amount);
            protocolFeesAccrued[currency] += protocolFees;
            restAmount = amount - protocolFees;
        }
    }

    // given an input amount of an asset and pair reserve, returns the maximum output amount of the other asset
    function _getAmountOut(PoolStatus memory status, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, uint24 fee, uint256 feeAmount)
    {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        require(reserveIn > 0 && reserveOut > 0, " INSUFFICIENT_LIQUIDITY");
        fee = marginFees.dynamicFee(status);
        uint256 amountInWithoutFee;
        (amountInWithoutFee, feeAmount) = fee.deduct(amountIn);
        uint256 numerator = amountInWithoutFee * reserveOut;
        uint256 denominator = reserveIn + amountInWithoutFee;
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserve, returns a required input amount of the other asset
    function _getAmountIn(PoolStatus memory status, bool zeroForOne, uint256 amountOut)
        internal
        view
        returns (uint256 amountIn, uint24 fee, uint256 feeAmount)
    {
        require(amountOut > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        require(amountOut < reserveOut, "OUTPUT_AMOUNT_OVERFLOW");
        fee = marginFees.dynamicFee(status);
        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = (reserveOut - amountOut);
        uint256 amountInWithoutFee = (numerator / denominator) + 1;
        (amountIn, feeAmount) = fee.attach(amountInWithoutFee);
    }

    // ******************** HOOK CALL ********************

    function initialize(PoolKey calldata key) external onlyHooks {
        PoolId id = key.toId();
        if (statusStore[id].key.currency1 > CurrencyLibrary.ADDRESS_ZERO) revert PairAlreadyExists();
        PoolStatus memory status;
        status.key = key;
        status.rate0CumulativeLast = PerLibrary.ONE_BILLION;
        status.rate1CumulativeLast = PerLibrary.ONE_BILLION;
        status.blockTimestampLast = uint32(block.timestamp % 2 ** 32);
        statusStore[id] = status;
    }

    function setBalances(PoolKey calldata key) external onlyHooks {
        _setBalances(key);
    }

    function updateBalances(PoolKey calldata key) external onlyHooks {
        _update(key);
    }

    function swap(PoolKey calldata key, IPoolManager.SwapParams calldata params)
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
        PoolStatus memory _status = getStatus(key.toId());
        bool exactInput = params.amountSpecified < 0;
        (specified, unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 feeAmount;
        if (exactInput) {
            (unspecifiedAmount, swapFee, feeAmount) = _getAmountOut(_status, params.zeroForOne, specifiedAmount);
            poolManager.approve(address(hooks), unspecified.toId(), unspecifiedAmount);
        } else {
            (unspecifiedAmount, swapFee, feeAmount) = _getAmountIn(_status, params.zeroForOne, specifiedAmount);
            poolManager.approve(address(hooks), specified.toId(), specifiedAmount);
        }
        if (feeAmount > 0) {
            _updateProtocolFees(specified, feeAmount);
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
        PoolStatus memory status = getStatus(params.poolId);
        _setBalances(status.key);
        uint256 uPoolId = marginLiquidity.getPoolId(params.poolId);
        {
            uint256 _totalSupply = marginLiquidity.balanceOf(address(this), uPoolId);
            if (_totalSupply == 0) {
                liquidity = Math.sqrt(params.amount0 * params.amount1);
                if (marginOracle != address(0)) {
                    IMarginOracleWriter(marginOracle).initialize(
                        status.key, uint112(params.amount0), uint112(params.amount1)
                    );
                }
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
        _update(status.key, false);
        emit Mint(params.poolId, msg.sender, params.to, liquidity, params.amount0, params.amount1);
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
        PoolStatus memory status = getStatus(params.poolId);
        _setBalances(status.key);
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
        _update(status.key);
        emit Burn(params.poolId, msg.sender, params.liquidity, amount0, amount1);
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

    function addPositionManager(address _marginPositionManager) external onlyOwner {
        positionManagers[_marginPositionManager] = true;
    }

    function setMarginFees(address _marginFees) external onlyOwner {
        marginFees = IMarginFees(_marginFees);
    }

    function setMarginOracle(address _oracle) external onlyOwner {
        marginOracle = _oracle;
    }

    function setFeeStatus(PoolId poolId, uint24 _marginFee) external onlyOwner {
        statusStore[poolId].marginFee = _marginFee;
    }

    // ******************** MARGIN FUNCTIONS ********************

    /// @inheritdoc IPairPoolManager
    function margin(MarginParams memory params) external onlyPosition returns (MarginParams memory) {
        bytes memory result = poolManager.unlock(abi.encodeCall(this.handleMargin, (msg.sender, params)));
        (params.marginTotal, params.borrowAmount) = abi.decode(result, (uint256, uint256));
        return params;
    }

    function handleMargin(address _positionManager, MarginParams calldata params)
        external
        selfOnly
        returns (uint256 marginWithoutFee, uint256 borrowAmount)
    {
        PoolStatus memory status = getStatus(params.poolId);
        BalanceStatus memory currentBalance = _setBalances(status.key);
        (Currency borrowCurrency, Currency marginCurrency) = params.marginForOne
            ? (status.key.currency0, status.key.currency1)
            : (status.key.currency1, status.key.currency0);
        uint256 marginFeeAmount;
        if (params.leverage > 0) {
            uint256 marginReserves;
            {
                (uint256 marginReserve0, uint256 marginReserve1) =
                    marginLiquidity.getFlowReserves(params.poolId, status);
                marginReserves = params.marginForOne ? marginReserve1 : marginReserve0;
            }
            uint256 marginTotal = params.marginAmount * params.leverage;
            require(marginReserves >= marginTotal, "TOKEN_NOT_ENOUGH");
            (borrowAmount,,) = _getAmountIn(status, params.marginForOne, marginTotal);
            (, uint24 marginFee) = marginFees.getPoolFees(address(this), params.poolId);
            // send total token
            (marginWithoutFee, marginFeeAmount) = marginFee.deduct(marginTotal);
            uint256 marginMirrorAmount =
                params.marginForOne ? currentBalance.mirrorBalance1 : currentBalance.mirrorBalance0;
            if (marginMirrorAmount > 0) {} else {
                marginCurrency.settle(poolManager, address(this), marginWithoutFee, true);
                marginCurrency.take(poolManager, _positionManager, marginWithoutFee, false);
            }
        } else {
            {
                uint24 minMarginLevel = marginFees.minMarginLevel();
                marginWithoutFee = params.marginAmount.mulMillionDiv(minMarginLevel);
                (uint256 reserve0, uint256 reserve1) = status.getReserves();
                (uint256 reserveBorrow, uint256 reserveMargin) =
                    params.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
                uint256 borrowMaxAmount = Math.mulDiv(marginWithoutFee, reserveBorrow, reserveMargin);
                if (params.borrowAmount > 0) {
                    borrowAmount = Math.min(borrowMaxAmount, params.borrowAmount);
                } else {
                    borrowAmount = borrowMaxAmount;
                }
            }
            uint256 borrowMirrorAmount =
                params.marginForOne ? currentBalance.mirrorBalance0 : currentBalance.mirrorBalance1;
            if (borrowMirrorAmount > 0) {} else {
                borrowCurrency.settle(poolManager, address(this), borrowAmount, true);
                borrowCurrency.take(poolManager, params.recipient, borrowAmount, false);
            }
        }

        if (marginFeeAmount > 0) {
            _updateProtocolFees(marginCurrency, marginFeeAmount);
        }

        // mint mirror token
        mirrorTokenManager.mint(borrowCurrency.toPoolId(params.poolId), borrowAmount);
        _update(status.key, true);
    }

    /// @inheritdoc IPairPoolManager
    function release(ReleaseParams memory params) external payable onlyPosition returns (uint256) {
        bytes memory result = poolManager.unlock(abi.encodeCall(this.handleRelease, (params)));
        return abi.decode(result, (uint256));
    }

    function handleRelease(ReleaseParams calldata params) external selfOnly returns (uint256) {
        PoolStatus memory status = getStatus(params.poolId);
        _updateInterests(status.key);
        _setBalances(status.key);
        (Currency borrowCurrency, Currency marginCurrency) = params.marginForOne
            ? (status.key.currency0, status.key.currency1)
            : (status.key.currency1, status.key.currency0);
        uint256 interest;
        if (params.releaseAmount > 0) {
            // release margin
            marginCurrency.settle(poolManager, params.payer, params.releaseAmount, false);
            marginCurrency.take(poolManager, address(this), params.releaseAmount, true);
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
        mirrorTokenManager.burn(borrowCurrency.toPoolId(params.poolId), params.repayAmount);
        if (interest > 0) {
            interest = _updateProtocolFees(borrowCurrency, interest);
        }
        _update(status.key, true);
        return params.repayAmount;
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
        amountCollected = (amount == 0) ? protocolFeesAccrued[currency] : amount;
        protocolFeesAccrued[currency] -= amountCollected;
        currency.settle(poolManager, address(this), amountCollected, true);
        currency.take(poolManager, recipient, amountCollected, false);
    }
}
