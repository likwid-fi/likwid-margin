// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// V4 core
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IPoolManager.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {CurrencyUtils} from "./libraries/CurrencyUtils.sol";

import {UQ112x112} from "./libraries/UQ112x112.sol";
import {TimeUtils} from "./libraries/TimeUtils.sol";
import {LiquidityLevel} from "./libraries/LiquidityLevel.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {IMarginHookManager} from "./interfaces/IMarginHookManager.sol";
import {IMarginFees} from "./interfaces/IMarginFees.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";
import {IMarginOracleWriter} from "./interfaces/IMarginOracleWriter.sol";
import {MarginPosition} from "./types/MarginPosition.sol";
import {MarginParams, ReleaseParams} from "./types/MarginParams.sol";
import {HookStatus} from "./types/HookStatus.sol";
import {BalanceStatus} from "./types/BalanceStatus.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "./types/LiquidityParams.sol";

contract MarginHookManager is IMarginHookManager, BaseHook, Owned {
    using UQ112x112 for uint224;
    using UQ112x112 for uint112;
    using SafeCast for uint256;
    using TimeUtils for uint32;
    using LiquidityLevel for uint8;
    using FeeLibrary for uint24;
    using PerLibrary for uint256;
    using CurrencyUtils for Currency;

    error InvalidInitialization();
    error UpdateBalanceGuardErrorCall();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurnt();
    error NotPositionManager();
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

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 public constant ONE_BILLION = 10 ** 9;
    bytes32 constant UPDATE_BALANCE_GUARD_SLOT = 0x885c9ad615c28a45189565668235695fb42940589d40d91c5c875c16cdc1bd4c;
    bytes32 constant BALANCE_0_SLOT = 0x608a02038d3023ed7e79ffc2a87ce7ad8c0bc0c5b839ddbe438db934c7b5e0e2;
    bytes32 constant BALANCE_1_SLOT = 0xba598ef587ec4c4cf493fe15321596d40159e5c3c0cbf449810c8c6894b2e5e1;
    bytes32 constant MIRROR_BALANCE_0_SLOT = 0x63450183817719ccac1ebea450ccc19412314611d078d8a8cb3ac9a1ef4de386;
    bytes32 constant MIRROR_BALANCE_1_SLOT = 0xbdb25f21ec501c2e41736c4e3dd44c1c3781af532b6899c36b3f72d4e003b0ab;

    IMirrorTokenManager public immutable mirrorTokenManager;
    IMarginLiquidity public immutable marginLiquidity;
    IMarginFees public marginFees;
    address public marginOracle;

    mapping(PoolId => HookStatus) private hookStatusStore;
    mapping(address => bool) private positionManagers;
    mapping(Currency currency => uint256 amount) public protocolFeesAccrued;

    constructor(
        address initialOwner,
        IPoolManager _manager,
        IMirrorTokenManager _mirrorTokenManager,
        IMarginLiquidity _marginLiquidity,
        IMarginFees _marginFees
    ) Owned(initialOwner) BaseHook(_manager) {
        mirrorTokenManager = _mirrorTokenManager;
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

    function getStatus(PoolId poolId) public view returns (HookStatus memory _status) {
        _status = hookStatusStore[poolId];
        if (_status.key.currency1 == CurrencyLibrary.ADDRESS_ZERO) revert PairNotExists();
    }

    function _getReserves(HookStatus memory status) internal pure returns (uint256 _reserve0, uint256 _reserve1) {
        _reserve0 = status.reserve0();
        _reserve1 = status.reserve1();
    }

    function getReserves(PoolId poolId) external view returns (uint256 _reserve0, uint256 _reserve1) {
        HookStatus memory status = getStatus(poolId);
        (_reserve0, _reserve1) = _getReserves(status);
    }

    function getAmountIn(PoolId poolId, bool zeroForOne, uint256 amountOut) external view returns (uint256 amountIn) {
        HookStatus memory status = getStatus(poolId);
        (amountIn,) = _getAmountIn(status, zeroForOne, amountOut);
    }

    function getAmountOut(PoolId poolId, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
        HookStatus memory status = getStatus(poolId);
        (amountOut,) = _getAmountOut(status, zeroForOne, amountIn);
    }

    // ******************** HOOK FUNCTIONS ********************

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (address(key.hooks) != address(this)) revert InvalidInitialization();
        PoolId id = key.toId();
        HookStatus memory status;
        status.key = key;
        status.rate0CumulativeLast = ONE_BILLION;
        status.rate1CumulativeLast = ONE_BILLION;
        status.blockTimestampLast = uint32(block.timestamp % 2 ** 32);
        hookStatusStore[id] = status;
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Facilitate a custom curve via beforeSwap + return delta
    /// @dev input tokens are taken from the PoolManager, creating a debt paid by the swapper
    /// @dev output tokens are transferred from the hook to the PoolManager, creating a credit claimed by the swapper
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        HookStatus memory hookStatus = getStatus(key.toId());
        bool exactInput = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 unspecifiedAmount;
        uint256 feeAmount;
        BeforeSwapDelta returnDelta;
        _setBalances(key);
        if (exactInput) {
            // in exact-input swaps, the specified token is a debt that gets paid down by the swapper
            // the unspecified token is credited to the PoolManager, that is claimed by the swapper
            (unspecifiedAmount, feeAmount) = _getAmountOut(hookStatus, params.zeroForOne, specifiedAmount);
            specified.take(poolManager, address(this), specifiedAmount, true);
            unspecified.settle(poolManager, address(this), unspecifiedAmount, true);
            returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount.toInt128());
        } else {
            // exactOutput
            // in exact-output swaps, the unspecified token is a debt that gets paid down by the swapper
            // the specified token is credited to the PoolManager, that is claimed by the swapper
            (unspecifiedAmount, feeAmount) = _getAmountIn(hookStatus, params.zeroForOne, specifiedAmount);
            unspecified.take(poolManager, address(this), unspecifiedAmount, true);
            specified.settle(poolManager, address(this), specifiedAmount, true);
            returnDelta = toBeforeSwapDelta(-specifiedAmount.toInt128(), unspecifiedAmount.toInt128());
        }
        if (feeAmount > 0) {
            _updateProtocolFees(specified, feeAmount);
        }
        _update(key);
        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    /// @notice No liquidity will be managed by v4 PoolManager
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert("No v4 Liquidity allowed");
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true, // -- disable v4 liquidity with a revert -- //
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // -- Custom Curve Handler --  //
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // -- Enables Custom Curves --  //
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ******************** INTERNAL FUNCTIONS ********************

    function _callSet() internal {
        if (_notCallUpdate()) {
            revert UpdateBalanceGuardErrorCall();
        }

        assembly ("memory-safe") {
            tstore(UPDATE_BALANCE_GUARD_SLOT, true)
        }
    }

    function _callUpdate() internal {
        assembly ("memory-safe") {
            tstore(UPDATE_BALANCE_GUARD_SLOT, false)
        }
    }

    function _notCallUpdate() internal view returns (bool value) {
        assembly ("memory-safe") {
            value := tload(UPDATE_BALANCE_GUARD_SLOT)
        }
    }

    function _getBalances() internal view returns (BalanceStatus memory) {
        uint256 balance0;
        uint256 balance1;
        uint256 mirrorBalance0;
        uint256 mirrorBalance1;
        assembly ("memory-safe") {
            balance0 := tload(BALANCE_0_SLOT)
            balance1 := tload(BALANCE_1_SLOT)
            mirrorBalance0 := tload(MIRROR_BALANCE_0_SLOT)
            mirrorBalance1 := tload(MIRROR_BALANCE_1_SLOT)
        }
        return BalanceStatus(balance0, balance1, mirrorBalance0, mirrorBalance1);
    }

    function _getBalances(PoolKey memory key) internal view returns (BalanceStatus memory balanceStatus) {
        balanceStatus.balance0 = poolManager.balanceOf(address(this), key.currency0.toId());
        if (balanceStatus.balance0 > protocolFeesAccrued[key.currency0]) {
            balanceStatus.balance0 -= protocolFeesAccrued[key.currency0];
        } else {
            balanceStatus.balance0 = 0;
        }
        balanceStatus.balance1 = poolManager.balanceOf(address(this), key.currency1.toId());
        if (balanceStatus.balance1 > protocolFeesAccrued[key.currency1]) {
            balanceStatus.balance1 -= protocolFeesAccrued[key.currency1];
        } else {
            balanceStatus.balance1 = 0;
        }
        balanceStatus.mirrorBalance0 = mirrorTokenManager.balanceOf(address(this), key.currency0.toKeyId(key));
        balanceStatus.mirrorBalance1 = mirrorTokenManager.balanceOf(address(this), key.currency1.toKeyId(key));
    }

    function _setBalances(PoolKey memory key) internal {
        _callSet();
        BalanceStatus memory balanceStatus = _getBalances(key);
        uint256 balance0 = balanceStatus.balance0;
        uint256 balance1 = balanceStatus.balance1;
        uint256 mirrorBalance0 = balanceStatus.mirrorBalance0;
        uint256 mirrorBalance1 = balanceStatus.mirrorBalance1;
        assembly ("memory-safe") {
            tstore(BALANCE_0_SLOT, balance0)
            tstore(BALANCE_1_SLOT, balance1)
            tstore(MIRROR_BALANCE_0_SLOT, mirrorBalance0)
            tstore(MIRROR_BALANCE_1_SLOT, mirrorBalance1)
        }
    }

    function _update(PoolKey memory key, bool fromMargin, uint112 _interest0, uint112 _interest1) internal {
        PoolId pooId = key.toId();
        HookStatus storage status = hookStatusStore[pooId];
        (uint32 blockTS, uint256 timeElapsed) = status.blockTimestampLast.getTimeElapsedMillisecond();
        // save margin price before changed
        if (fromMargin) {
            if (status.marginTimestampLast != blockTS) {
                status.marginTimestampLast = blockTS;
                status.lastPrice1X112 = status.getPrice1X112();
            }
            if (status.lastPrice1X112 == 0) status.lastPrice1X112 = status.getPrice1X112();
        }

        (status.rate0CumulativeLast, status.rate1CumulativeLast) =
            marginFees.getBorrowRateCumulativeLast(status, timeElapsed);

        status.blockTimestampLast = blockTS;
        BalanceStatus memory beforeStatus = _getBalances();
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
        if (_interest0 > 0) {
            status.interestRatio0X112 = uint112(_interest0.encode().div(_reserve0));
        }
        if (_interest1 > 0) {
            status.interestRatio1X112 = uint112(_interest1.encode().div(_reserve1));
        }
        emit Sync(pooId, status.realReserve0, status.realReserve1, status.mirrorReserve0, status.mirrorReserve1);
        _callUpdate();
    }

    function _update(PoolKey memory key) internal {
        _update(key, false, 0, 0);
    }

    function _updateProtocolFees(Currency currency, uint256 amount) internal returns (uint256 restAmount) {
        unchecked {
            uint256 protocolFees = marginFees.getProtocolFeeAmount(amount);
            protocolFeesAccrued[currency] += protocolFees;
            restAmount = amount - protocolFees;
        }
    }

    // given an input amount of an asset and pair reserve, returns the maximum output amount of the other asset
    function _getAmountOut(HookStatus memory status, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        (uint256 _reserve0, uint256 _reserve1) = _getReserves(status);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        require(reserveIn > 0 && reserveOut > 0, " INSUFFICIENT_LIQUIDITY");
        uint24 _fee = marginFees.dynamicFee(status);
        uint256 amountInWithoutFee;
        (amountInWithoutFee, feeAmount) = _fee.deduct(amountIn);
        uint256 numerator = amountInWithoutFee * reserveOut;
        uint256 denominator = reserveIn + amountInWithoutFee;
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserve, returns a required input amount of the other asset
    function _getAmountIn(HookStatus memory status, bool zeroForOne, uint256 amountOut)
        internal
        view
        returns (uint256 amountIn, uint256 feeAmount)
    {
        require(amountOut > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint256 _reserve0, uint256 _reserve1) = _getReserves(status);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        require(amountOut < reserveOut, "OUTPUT_AMOUNT_OVERFLOW");
        uint24 _fee = marginFees.dynamicFee(status);
        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = (reserveOut - amountOut);
        uint256 amountInWithoutFee = (numerator / denominator) + 1;
        (amountIn, feeAmount) = _fee.attach(amountInWithoutFee);
    }

    // ******************** SELF CALL ********************

    /// @inheritdoc IMarginHookManager
    function addLiquidity(AddLiquidityParams calldata params)
        external
        payable
        ensure(params.deadline)
        returns (uint256 liquidity)
    {
        require(params.amount0 > 0 && params.amount1 > 0, "AMOUNT_ERR");
        HookStatus memory status = getStatus(params.poolId);
        _setBalances(status.key);
        uint256 uPoolId = marginLiquidity.getPoolId(params.poolId);
        (uint112 interest0, uint112 interest1) = marginFees.getInterests(status);
        {
            (uint256 _reserve0, uint256 _reserve1) = _getReserves(status);
            uint256 _totalSupply = marginLiquidity.balanceOf(address(this), uPoolId);
            if (_reserve1 > 0 && _totalSupply > MINIMUM_LIQUIDITY) {
                uint256 upValue = _reserve0.upperMillion(_reserve1, params.tickUpper);
                uint256 downValue = _reserve0.lowerMillion(_reserve1, params.tickLower);
                uint256 inValue = params.amount0.mulMillionDiv(params.amount1);
                require(inValue >= downValue && inValue <= upValue, "OUT_OF_RANGE");
            }

            if (_totalSupply == 0) {
                liquidity = Math.sqrt(params.amount0 * params.amount1) - MINIMUM_LIQUIDITY;
                marginLiquidity.mint(address(this), uPoolId, MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
                if (marginOracle != address(0)) {
                    IMarginOracleWriter(marginOracle).initialize(
                        status.key, uint112(params.amount0), uint112(params.amount1)
                    );
                }
            } else {
                liquidity =
                    Math.min(params.amount0 * _totalSupply / _reserve0, params.amount1 * _totalSupply / _reserve1);
            }
            if (liquidity == 0) revert InsufficientLiquidityMinted();
        }
        marginLiquidity.addLiquidity(params.to, uPoolId, params.level, liquidity);
        poolManager.unlock(
            abi.encodeCall(this.handleAddLiquidity, (msg.sender, status.key, params.amount0, params.amount1))
        );
        _update(status.key, false, interest0, interest1);
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

    /// @inheritdoc IMarginHookManager
    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        ensure(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        HookStatus memory status = getStatus(params.poolId);
        _setBalances(status.key);
        uint256 uPoolId = marginLiquidity.getPoolId(params.poolId);
        (uint112 interest0, uint112 interest1) = marginFees.getInterests(status);
        {
            (uint256 _reserve0, uint256 _reserve1) = _getReserves(status);
            (uint256 _totalSupply, uint256 retainSupply0, uint256 retainSupply1) = marginLiquidity.getSupplies(uPoolId);
            uint256 maxReserve0 = status.realReserve0;
            uint256 maxReserve1 = status.realReserve1;
            // currency0 enable margin,can claim interest1
            if (params.level.zeroForMargin()) {
                amount1 = Math.mulDiv(params.liquidity, _reserve1, _totalSupply);
                uint256 retainAmount0 = Math.mulDiv(retainSupply0, _reserve0, _totalSupply);
                if (maxReserve0 > retainAmount0) {
                    maxReserve0 -= retainAmount0;
                } else {
                    maxReserve0 = 0;
                }
                interest1 = interest1.scaleDown(amount1, _reserve1);
            } else {
                amount1 = Math.mulDiv(params.liquidity, (_reserve1 - interest1), _totalSupply);
            }
            // currency1 enable margin,can claim interest0
            if (params.level.oneForMargin()) {
                amount0 = Math.mulDiv(params.liquidity, _reserve0, _totalSupply);
                uint256 retainAmount1 = Math.mulDiv(retainSupply1, _reserve1, _totalSupply);
                if (maxReserve1 > retainAmount1) {
                    maxReserve1 -= retainAmount1;
                } else {
                    maxReserve1 = 0;
                }
                interest0 = interest0.scaleDown(amount0, _reserve0);
            } else {
                amount0 = Math.mulDiv(params.liquidity, (_reserve0 - interest0), _totalSupply);
            }
            require(amount0 <= maxReserve0 && amount1 <= maxReserve1, "NOT_ENOUGH_RESERVE");
            if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurnt();
        }

        marginLiquidity.removeLiquidity(msg.sender, uPoolId, params.level, params.liquidity);
        poolManager.unlock(abi.encodeCall(this.handleRemoveLiquidity, (msg.sender, status.key, amount0, amount1)));
        _update(status.key, false, interest0, interest1);
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
        hookStatusStore[poolId].marginFee = _marginFee;
    }

    // ******************** MARGIN FUNCTIONS ********************

    /// @inheritdoc IMarginHookManager
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
        HookStatus memory status = getStatus(params.poolId);
        _setBalances(status.key);
        (Currency borrowCurrency, Currency marginCurrency) = params.marginForOne
            ? (status.key.currency0, status.key.currency1)
            : (status.key.currency1, status.key.currency0);
        bool zeroForOne = params.marginForOne;
        uint256 marginReserves;
        {
            uint256 uPoolId = marginLiquidity.getPoolId(params.poolId);
            (uint256 _totalSupply, uint256 retainSupply0, uint256 retainSupply1) = marginLiquidity.getSupplies(uPoolId);
            uint256 marginReserve0 = (_totalSupply - retainSupply0) * status.realReserve0 / _totalSupply;
            uint256 marginReserve1 = (_totalSupply - retainSupply1) * status.realReserve1 / _totalSupply;
            marginReserves = params.marginForOne ? marginReserve1 : marginReserve0;
        }
        uint256 marginTotal = params.marginAmount * params.leverage;
        require(marginReserves >= marginTotal, "TOKEN_NOT_ENOUGH");
        (borrowAmount,) = _getAmountIn(status, zeroForOne, marginTotal);
        (, uint24 marginFee) = marginFees.getPoolFees(address(this), params.poolId);
        // send total token
        uint256 marginFeeAmount;
        (marginWithoutFee, marginFeeAmount) = marginFee.deduct(marginTotal);
        if (marginFeeAmount > 0) {
            _updateProtocolFees(marginCurrency, marginFeeAmount);
        }
        marginCurrency.settle(poolManager, address(this), marginWithoutFee, true);
        marginCurrency.take(poolManager, _positionManager, marginWithoutFee, false);
        // mint mirror token
        mirrorTokenManager.mint(borrowCurrency.toKeyId(status.key), borrowAmount);
        _update(status.key, true, 0, 0);
    }

    /// @inheritdoc IMarginHookManager
    function release(ReleaseParams memory params) external payable onlyPosition returns (uint256) {
        bytes memory result = poolManager.unlock(abi.encodeCall(this.handleRelease, (params)));
        return abi.decode(result, (uint256));
    }

    function handleRelease(ReleaseParams calldata params) external selfOnly returns (uint256) {
        HookStatus memory status = getStatus(params.poolId);
        _setBalances(status.key);
        (Currency borrowCurrency, Currency marginCurrency) = params.marginForOne
            ? (status.key.currency0, status.key.currency1)
            : (status.key.currency1, status.key.currency0);
        (uint112 interest0, uint112 interest1) = marginFees.getInterests(status);
        uint256 interest;
        if (params.releaseAmount > 0) {
            // release margin
            marginCurrency.settle(poolManager, params.payer, params.releaseAmount, false);
            marginCurrency.take(poolManager, address(this), params.releaseAmount, true);
            if (params.repayAmount > params.rawBorrowAmount) {
                uint256 overRepay = params.repayAmount - params.rawBorrowAmount;
                interest = overRepay * params.releaseAmount / params.repayAmount;
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
        mirrorTokenManager.burn(borrowCurrency.toKeyId(status.key), params.rawBorrowAmount);
        if (interest > 0) {
            interest = _updateProtocolFees(borrowCurrency, interest);
            params.marginForOne ? interest0 += uint112(interest) : interest1 += uint112(interest);
            _update(status.key, true, interest0, interest1);
        } else {
            _update(status.key, true, 0, 0);
        }
        return params.repayAmount;
    }

    /// @inheritdoc IMarginHookManager
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
