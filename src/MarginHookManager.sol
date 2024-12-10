// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// V4 core
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IPoolManager.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {ERC6909Claims} from "v4-core/ERC6909Claims.sol";
// Solmate
import {ERC20} from "solmate/src/Tokens/ERC20.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {CurrencyUtils} from "./libraries/CurrencyUtils.sol";
import {Math} from "./libraries/Math.sol";
import {IMarginHookManager} from "./interfaces/IMarginHookManager.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {IMarginOracleWriter} from "./interfaces/IMarginOracleWriter.sol";
import {MarginPosition} from "./types/MarginPosition.sol";
import {MarginParams, ReleaseParams} from "./types/MarginParams.sol";
import {RateStatus} from "./types/RateStatus.sol";
import {HookStatus, BalanceStatus, FeeStatus} from "./types/HookStatus.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "./types/LiquidityParams.sol";

contract MarginHookManager is IMarginHookManager, BaseHook, ERC6909Claims, Owned {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencyUtils for Currency;

    error InvalidInitialization();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurnt();
    error NotPositionManager();
    error PairNotExists();

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
        uint256 amount1
    );
    event Burn(PoolId indexed poolId, address indexed sender, uint256 liquidity, uint256 amount0, uint256 amount1);
    event Sync(
        PoolId indexed poolId, uint256 reserve0, uint256 reserve1, uint256 mirrorReserve0, uint256 mirrorReserve1
    );

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 public constant ONE_BILLION = 10 ** 9;
    uint256 public constant YEAR_SECONDS = 365 * 24 * 3600;
    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    bytes32 constant BALANCE_0_SLOT = 0x608a02038d3023ed7e79ffc2a87ce7ad8c0bc0c5b839ddbe438db934c7b5e0e2;
    bytes32 constant BALANCE_1_SLOT = 0xba598ef587ec4c4cf493fe15321596d40159e5c3c0cbf449810c8c6894b2e5e1;
    bytes32 constant MIRROR_BALANCE_0_SLOT = 0x63450183817719ccac1ebea450ccc19412314611d078d8a8cb3ac9a1ef4de386;
    bytes32 constant MIRROR_BALANCE_1_SLOT = 0xbdb25f21ec501c2e41736c4e3dd44c1c3781af532b6899c36b3f72d4e003b0ab;

    IMirrorTokenManager public immutable mirrorTokenManager;

    uint24 initialLTV = 500000; // 50%
    uint24 liquidationLTV = 900000; // 90%

    address public feeTo;
    uint24 protocolFee = 3000; // 0.3%
    uint24 protocolMarginFee = 5000; // 0.5%

    address public marginOracle;

    mapping(PoolId => HookStatus) public hookStatusStore;
    mapping(address => bool) public positionManagers;
    RateStatus public rateStatus;

    constructor(address initialOwner, IPoolManager _manager, IMirrorTokenManager _mirrorTokenManager)
        Owned(initialOwner)
        BaseHook(_manager)
    {
        rateStatus = RateStatus({rateBase: 50000, useHighLevel: 700000, mLow: 10, mHigh: 50});
        mirrorTokenManager = _mirrorTokenManager;
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    modifier positionOnly() {
        if (!(positionManagers[msg.sender] && IMarginPositionManager(msg.sender).getHook() == address(this))) {
            revert NotPositionManager();
        }
        _;
    }

    function _setBalances(PoolKey memory key) internal {
        uint256 balance0 = poolManager.balanceOf(address(this), key.currency0.toId());
        uint256 balance1 = poolManager.balanceOf(address(this), key.currency1.toId());
        uint256 mirrorBalance0 = mirrorTokenManager.balanceOf(address(this), key.currency0.toKeyId(key));
        uint256 mirrorBalance1 = mirrorTokenManager.balanceOf(address(this), key.currency1.toKeyId(key));
        assembly {
            tstore(BALANCE_0_SLOT, balance0)
            tstore(BALANCE_1_SLOT, balance1)
            tstore(MIRROR_BALANCE_0_SLOT, mirrorBalance0)
            tstore(MIRROR_BALANCE_1_SLOT, mirrorBalance1)
        }
    }

    function getStatus(PoolId poolId) public view returns (HookStatus memory _status) {
        _status = hookStatusStore[poolId];
        if (_status.key.currency1 == CurrencyLibrary.ADDRESS_ZERO) revert PairNotExists();
    }

    function _getReserves(HookStatus memory status)
        internal
        pure
        returns (uint256 _reserve0, uint256 _reserve1, FeeStatus memory feeStatus)
    {
        _reserve0 = status.reserve0 + status.mirrorReserve0;
        _reserve1 = status.reserve1 + status.mirrorReserve1;
        feeStatus = status.feeStatus;
    }

    function getReserves(PoolId poolId) external view returns (uint256 _reserve0, uint256 _reserve1) {
        HookStatus memory status = getStatus(poolId);
        (_reserve0, _reserve1,) = _getReserves(status);
    }

    function ltvParameters(PoolId poolId) external view returns (uint24 _initialLTV, uint24 _liquidationLTV) {
        HookStatus memory status = getStatus(poolId);
        _initialLTV = status.feeStatus.initialLTV == 0 ? initialLTV : status.feeStatus.initialLTV;
        _liquidationLTV = status.feeStatus.liquidationLTV == 0 ? liquidationLTV : status.feeStatus.liquidationLTV;
    }

    function checkFeeOn() public view returns (bool feeOn) {
        feeOn = feeTo != address(0);
    }

    function getBorrowRate(PoolId poolId, bool marginForOne) external view returns (uint256) {
        HookStatus memory status = getStatus(poolId);
        uint256 tokenReserve = marginForOne ? status.reserve0 : status.reserve1;
        uint256 mirrorReserve = marginForOne ? status.mirrorReserve0 : status.mirrorReserve1;
        return _getBorrowRate(tokenReserve, mirrorReserve);
    }

    function getBorrowRateCumulativeLast(PoolId poolId, bool marginForOne) external view returns (uint256) {
        HookStatus memory status = getStatus(poolId);
        return marginForOne ? status.rate0CumulativeLast : status.rate1CumulativeLast;
    }

    function getAmountIn(PoolId poolId, bool zeroForOne, uint256 amountOut) external view returns (uint256 amountIn) {
        HookStatus memory status = getStatus(poolId);
        (amountIn,) = _getAmountIn(status, zeroForOne, amountOut);
    }

    function getAmountOut(PoolId poolId, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
        HookStatus memory status = getStatus(poolId);
        (amountOut,) = _getAmountOut(status, zeroForOne, amountIn);
    }

    function getProtocolFees() external view returns (uint24 _protocolFee, uint24 _protocolMarginFee) {
        if (checkFeeOn()) {
            _protocolFee = protocolFee;
            _protocolMarginFee = protocolMarginFee;
        }
    }

    function initialize(PoolKey calldata key) external {
        PoolId id = key.toId();
        HookStatus memory status;
        status.key = key;
        status.rate0CumulativeLast = ONE_BILLION;
        status.rate1CumulativeLast = ONE_BILLION;
        status.blockTimestampLast = uint32(block.timestamp % 2 ** 32);
        status.feeStatus.marginFee = 15000; // 1.5%
        hookStatusStore[id] = status;
        poolManager.initialize(key, SQRT_RATIO_1_1);
        emit Initialize(id, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
    }

    // ******************** HOOK FUNCTIONS ********************

    function beforeInitialize(address, PoolKey calldata key, uint160) external view override returns (bytes4) {
        if (address(key.hooks) != address(this)) revert InvalidInitialization();
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Facilitate a custom curve via beforeSwap + return delta
    /// @dev input tokens are taken from the PoolManager, creating a debt paid by the swapper
    /// @dev output tokens are transferred from the hook to the PoolManager, creating a credit claimed by the swapper
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        HookStatus memory hookStatus = getStatus(key.toId());
        bool exactInput = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 unspecifiedAmount;
        uint256 protocolFeeAmount;
        BeforeSwapDelta returnDelta;
        _setBalances(key);
        if (exactInput) {
            // in exact-input swaps, the specified token is a debt that gets paid down by the swapper
            // the unspecified token is credited to the PoolManager, that is claimed by the swapper
            (unspecifiedAmount, protocolFeeAmount) = _getAmountOut(hookStatus, params.zeroForOne, specifiedAmount);
            specified.take(poolManager, address(this), specifiedAmount - protocolFeeAmount, true);
            unspecified.settle(poolManager, address(this), unspecifiedAmount, true);
            if (protocolFeeAmount > 0) {
                specified.take(poolManager, feeTo, protocolFeeAmount, false);
            }
            returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount.toInt128());
        } else {
            // exactOutput
            // in exact-output swaps, the unspecified token is a debt that gets paid down by the swapper
            // the specified token is credited to the PoolManager, that is claimed by the swapper
            (unspecifiedAmount, protocolFeeAmount) = _getAmountIn(hookStatus, params.zeroForOne, specifiedAmount);
            unspecified.take(poolManager, address(this), unspecifiedAmount - protocolFeeAmount, true);
            specified.settle(poolManager, address(this), specifiedAmount, true);
            if (protocolFeeAmount > 0) {
                unspecified.take(poolManager, feeTo, protocolFeeAmount, false);
            }
            returnDelta = toBeforeSwapDelta(-specifiedAmount.toInt128(), unspecifiedAmount.toInt128());
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
            beforeInitialize: false,
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

    function _getBalances() internal view returns (BalanceStatus memory) {
        uint256 balance0;
        uint256 balance1;
        uint256 mirrorBalance0;
        uint256 mirrorBalance1;
        assembly {
            balance0 := tload(BALANCE_0_SLOT)
            balance1 := tload(BALANCE_1_SLOT)
            mirrorBalance0 := tload(MIRROR_BALANCE_0_SLOT)
            mirrorBalance1 := tload(MIRROR_BALANCE_1_SLOT)
        }
        return BalanceStatus(balance0, balance1, mirrorBalance0, mirrorBalance1);
    }

    function _getBalances(PoolKey memory key) internal view returns (BalanceStatus memory balanceStatus) {
        balanceStatus.balance0 = poolManager.balanceOf(address(this), key.currency0.toId());
        balanceStatus.balance1 = poolManager.balanceOf(address(this), key.currency1.toId());
        balanceStatus.mirrorBalance0 = mirrorTokenManager.balanceOf(address(this), key.currency0.toKeyId(key));
        balanceStatus.mirrorBalance1 = mirrorTokenManager.balanceOf(address(this), key.currency1.toKeyId(key));
    }

    function _update(PoolKey memory key) internal {
        PoolId pooId = key.toId();
        HookStatus storage status = hookStatusStore[pooId];
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        uint256 timeElapsed = (blockTS - status.blockTimestampLast) * 10 ** 3;
        uint256 rate0Last =
            ONE_BILLION + _getBorrowRate(status.reserve0, status.mirrorReserve0) * timeElapsed / YEAR_SECONDS;
        uint256 rate1Last =
            ONE_BILLION + _getBorrowRate(status.reserve1, status.mirrorReserve1) * timeElapsed / YEAR_SECONDS;
        status.rate0CumulativeLast = status.rate0CumulativeLast * rate0Last / ONE_BILLION;
        status.rate1CumulativeLast = status.rate1CumulativeLast * rate1Last / ONE_BILLION;
        status.blockTimestampLast = blockTS;
        BalanceStatus memory balanceStatus = _getBalances();
        BalanceStatus memory nowBalanceStatus = _getBalances(key);

        status.reserve0 = status.reserve0 + uint112(nowBalanceStatus.balance0) - uint112(balanceStatus.balance0);
        status.reserve1 = status.reserve1 + uint112(nowBalanceStatus.balance1) - uint112(balanceStatus.balance1);
        status.mirrorReserve0 =
            status.mirrorReserve0 + uint112(nowBalanceStatus.mirrorBalance0) - uint112(balanceStatus.mirrorBalance0);
        status.mirrorReserve1 =
            status.mirrorReserve1 + uint112(nowBalanceStatus.mirrorBalance1) - uint112(balanceStatus.mirrorBalance1);

        if (marginOracle != address(0)) {
            IMarginOracleWriter(marginOracle).write(
                status.key, status.reserve0 + status.mirrorReserve0, status.reserve1 + status.mirrorReserve1
            );
        }
        emit Sync(pooId, status.reserve0, status.reserve1, status.mirrorReserve0, status.mirrorReserve1);
    }

    // given an input amount of an asset and pair reserve, returns the maximum output amount of the other asset
    function _getAmountOut(HookStatus memory status, bool zeroForOne, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        (uint256 _reserve0, uint256 _reserve1, FeeStatus memory feeStatus) = _getReserves(status);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        require(reserveIn > 0 && reserveOut > 0, " INSUFFICIENT_LIQUIDITY");
        uint256 ratio = ONE_MILLION - status.key.fee;
        if (checkFeeOn()) {
            uint24 _protocolFee = feeStatus.protocolFee == 0 ? protocolFee : feeStatus.protocolFee;
            feeAmount = amountIn * _protocolFee / ONE_MILLION;
            ratio -= _protocolFee;
        }
        uint256 amountInWithFee = amountIn * ratio;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * ONE_MILLION) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserve, returns a required input amount of the other asset
    function _getAmountIn(HookStatus memory status, bool zeroForOne, uint256 amountOut)
        internal
        view
        returns (uint256 amountIn, uint256 feeAmount)
    {
        require(amountOut > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint256 _reserve0, uint256 _reserve1, FeeStatus memory feeStatus) = _getReserves(status);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        require(amountOut < reserveOut, "OUTPUT_AMOUNT_OVERFLOW");
        uint256 ratio = ONE_MILLION - status.key.fee;
        uint256 numerator = reserveIn * amountOut * ONE_MILLION;
        uint256 denominator = (reserveOut - amountOut) * ratio;
        amountIn = (numerator / denominator) + 1;
        if (checkFeeOn()) {
            uint24 _protocolFee = feeStatus.protocolFee == 0 ? protocolFee : feeStatus.protocolFee;
            ratio -= _protocolFee;
            denominator = (reserveOut - amountOut) * ratio;
            feeAmount = ((numerator / denominator) + 1) - amountIn;
            amountIn += feeAmount;
        }
    }

    function _getBorrowRate(uint256 tokenReserve, uint256 mirrorReserve) internal view returns (uint256) {
        if (tokenReserve == 0) {
            return rateStatus.rateBase;
        }
        uint256 useLevel = mirrorReserve * ONE_MILLION / (mirrorReserve + tokenReserve);
        if (useLevel >= rateStatus.useHighLevel) {
            return rateStatus.rateBase + rateStatus.useHighLevel * rateStatus.mLow
                + (useLevel - rateStatus.useHighLevel) * rateStatus.mHigh;
        }
        return rateStatus.rateBase + useLevel * rateStatus.mLow;
    }

    // ******************** SELF CALL ********************

    function addLiquidity(AddLiquidityParams calldata params)
        external
        payable
        ensure(params.deadline)
        returns (uint256 liquidity)
    {
        require(params.amount0 > 0 && params.amount1 > 0, "AMOUNT_ERR");
        HookStatus memory status = getStatus(params.poolId);
        _setBalances(status.key);
        uint256 uPoolId = uint256(PoolId.unwrap(params.poolId));
        (uint256 _reserve0, uint256 _reserve1,) = _getReserves(status);
        uint256 _totalSupply = balanceOf[address(this)][uPoolId];
        if (_reserve1 > 0 && _totalSupply > MINIMUM_LIQUIDITY) {
            uint256 upValue = _reserve0 * (ONE_MILLION + params.tickUpper) / _reserve1;
            uint256 downValue = _reserve0 * (ONE_MILLION - params.tickLower) / _reserve1;
            uint256 inValue = params.amount0 * ONE_MILLION / params.amount1;
            require(inValue >= downValue && inValue <= upValue, "OUT_OF_RANGE");
        }

        if (_totalSupply == 0) {
            liquidity = Math.sqrt(params.amount0 * params.amount1) - MINIMUM_LIQUIDITY;
            _mint(address(this), uPoolId, MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
            if (marginOracle != address(0)) {
                IMarginOracleWriter(marginOracle).initialize(
                    status.key, uint112(params.amount0), uint112(params.amount1)
                );
            }
        } else {
            liquidity = Math.min(params.amount0 * _totalSupply / _reserve0, params.amount1 * _totalSupply / _reserve1);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();

        _mint(address(this), uPoolId, liquidity);
        _mint(params.to, uPoolId, liquidity);
        poolManager.unlock(
            abi.encodeCall(this.handleAddLiquidity, (msg.sender, status.key, params.amount0, params.amount1))
        );
        _update(status.key);
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

    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        ensure(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        HookStatus memory status = getStatus(params.poolId);
        _setBalances(status.key);
        uint256 uPoolId = uint256(PoolId.unwrap(params.poolId));
        uint256 _totalSupply = balanceOf[address(this)][uPoolId];
        (uint256 _reserve0, uint256 _reserve1,) = _getReserves(status);

        amount0 = params.liquidity * _reserve0 / _totalSupply;
        amount1 = params.liquidity * _reserve1 / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurnt();

        _burn(address(this), uPoolId, params.liquidity);
        _burn(msg.sender, uPoolId, params.liquidity);
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

    function addPositionManager(address _marginPositionManager) external onlyOwner {
        positionManagers[_marginPositionManager] = true;
    }

    function setLTV(uint24 _initialLTV, uint24 _liquidationLTV) external onlyOwner {
        initialLTV = _initialLTV;
        liquidationLTV = _liquidationLTV;
    }

    function setFeeTo(address _feeTo, uint24 _protocolFee, uint24 _protocolMarginFee) external onlyOwner {
        feeTo = _feeTo;
        protocolFee = _protocolFee;
        protocolMarginFee = _protocolMarginFee;
    }

    function setMarginOracle(address _oracle) external onlyOwner {
        marginOracle = _oracle;
    }

    function setFeeStatus(PoolId poolId, FeeStatus calldata feeStatus) external onlyOwner {
        hookStatusStore[poolId].feeStatus = feeStatus;
    }

    function withdrawFee(address token, address to, uint256 amount) external onlyOwner returns (bool success) {
        success = Currency.wrap(token).transfer(to, address(this), amount);
    }

    // ******************** MARGIN FUNCTIONS ********************

    function getMarginTotal(PoolId poolId, bool marginForOne, uint24 leverage, uint256 marginAmount)
        external
        view
        returns (uint256 marginWithoutFee, uint256 borrowAmount)
    {
        HookStatus memory status = getStatus(poolId);
        uint24 _initialLTV = status.feeStatus.initialLTV > 0 ? status.feeStatus.initialLTV : initialLTV;
        uint256 marginTotal = marginAmount * leverage * _initialLTV / ONE_MILLION;
        bool zeroForOne = marginForOne;
        (borrowAmount,) = _getAmountIn(status, zeroForOne, marginTotal);
        (marginTotal,) = _getAmountOut(status, zeroForOne, borrowAmount);
        marginWithoutFee = marginTotal * (ONE_MILLION - status.feeStatus.marginFee) / ONE_MILLION;
        if (checkFeeOn()) {
            uint256 protocolMarginFeeAmount = marginTotal * protocolMarginFee / ONE_MILLION;
            marginWithoutFee -= protocolMarginFeeAmount;
        }
    }

    function getMarginMax(PoolId poolId, bool marginForOne, uint24 leverage)
        external
        view
        returns (uint256 marginMax, uint256 borrowAmount)
    {
        HookStatus memory status = getStatus(poolId);
        uint24 _initialLTV = status.feeStatus.initialLTV > 0 ? status.feeStatus.initialLTV : initialLTV;
        bool zeroForOne = marginForOne;
        borrowAmount = zeroForOne ? status.reserve0 : status.reserve1;
        (uint256 marginMaxTotal,) = _getAmountOut(status, zeroForOne, borrowAmount);
        marginMax = marginMaxTotal * ONE_MILLION / leverage / _initialLTV;
    }

    function margin(MarginParams memory params) external positionOnly returns (MarginParams memory) {
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
        uint256 borrowReserves = zeroForOne ? status.reserve0 : status.reserve1;
        uint24 _initialLTV = status.feeStatus.initialLTV > 0 ? status.feeStatus.initialLTV : initialLTV;
        uint256 marginTotal = params.marginAmount * params.leverage * _initialLTV / ONE_MILLION;
        (borrowAmount,) = _getAmountIn(status, zeroForOne, marginTotal);
        require(borrowReserves > borrowAmount, "TOKEN_NOT_ENOUGH");
        (marginTotal,) = _getAmountOut(status, zeroForOne, borrowAmount);
        // send total token
        marginWithoutFee = marginTotal * (ONE_MILLION - status.feeStatus.marginFee) / ONE_MILLION;
        marginCurrency.settle(poolManager, address(this), marginWithoutFee, true);
        if (checkFeeOn()) {
            uint256 protocolMarginFeeAmount = marginTotal * protocolMarginFee / ONE_MILLION;
            marginCurrency.take(poolManager, feeTo, protocolMarginFeeAmount, false);
            marginWithoutFee -= protocolMarginFeeAmount;
        }
        marginCurrency.take(poolManager, _positionManager, marginWithoutFee, false);
        // mint mirror token
        mirrorTokenManager.mint(borrowCurrency.toKeyId(status.key), borrowAmount);
        _update(status.key);
    }

    function release(ReleaseParams memory params) external payable positionOnly returns (uint256) {
        bytes memory result = poolManager.unlock(abi.encodeCall(this.handleRelease, (params)));
        return abi.decode(result, (uint256));
    }

    function handleRelease(ReleaseParams calldata params) external selfOnly returns (uint256) {
        HookStatus memory status = getStatus(params.poolId);
        _setBalances(status.key);
        (Currency borrowCurrency, Currency marginCurrency) = params.marginForOne
            ? (status.key.currency0, status.key.currency1)
            : (status.key.currency1, status.key.currency0);
        if (params.releaseAmount > 0) {
            // release margin
            marginCurrency.settle(poolManager, params.payer, params.releaseAmount, false);
            marginCurrency.take(poolManager, address(this), params.releaseAmount, true);
        } else if (params.repayAmount > 0) {
            // repay borrow
            borrowCurrency.settle(poolManager, params.payer, params.repayAmount, false);
            borrowCurrency.take(poolManager, address(this), params.repayAmount, true);
        }
        // burn mirror token
        mirrorTokenManager.burnScale(borrowCurrency.toKeyId(status.key), params.borrowAmount, params.repayAmount);
        _update(status.key);
        return params.repayAmount;
    }
}
