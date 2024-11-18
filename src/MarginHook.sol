// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// V4 core
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
// Solmate
import {ERC20} from "solmate/src/Tokens/ERC20.sol";
// Local
import {CurrencySettleTake} from "./libraries/CurrencySettleTake.sol";
import {Math} from "./libraries/Math.sol";
import {UnsafeMath} from "./libraries/UnsafeMath.sol";
import {IMarginHook} from "./interfaces/IMarginHook.sol";
import {IMarginHookFactory} from "./interfaces/IMarginHookFactory.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {MarginPosition} from "./types/MarginPosition.sol";
import {BorrowParams} from "./types/BorrowParams.sol";
import {RateStatus} from "./types/RateStatus.sol";

contract MarginHook is IMarginHook, BaseHook, ERC20 {
    using UnsafeMath for uint256;
    using SafeCast for uint256;
    using CurrencySettleTake for Currency;
    using CurrencyLibrary for Currency;

    error BalanceOverflow();
    error InvalidInitialization();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurnt();
    error AddLiquidityDirectToHook();
    error IncorrectSwapAmount();
    error NotFactory();
    error NotPositionManager();

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(uint256 amountIn, uint256 amountOut);
    event Sync(uint256 reserve0, uint256 reserve1);

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 public constant YEAR_SECONDS = 365 * 24 * 3600;

    Currency public immutable currency0;
    Currency public immutable currency1;
    address public immutable factory;
    IMirrorTokenManager public immutable mirrorTokenManager;
    IMarginPositionManager public immutable marginPositionManager;

    uint256 private reserve0;
    uint256 private reserve1;
    uint256 private blockTimestampLast; // uses single storage slot, accessible via getReserves
    uint256 public rate0CumulativeLast;
    uint256 public rate1CumulativeLast;
    uint256 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint24 public initialLTV = 500000; // 50%
    uint24 public liquidationLTV = 900000; // 90%
    uint24 public fee = 6000; // 0.6%
    RateStatus public rateStatus;

    constructor(IPoolManager _manager, string memory _name, string memory _symbol)
        BaseHook(_manager)
        ERC20(_name, _symbol, 18)
    {
        (currency0, currency1, fee, mirrorTokenManager, marginPositionManager) =
            IMarginHookFactory(msg.sender).parameters();
        factory = msg.sender;
        rateStatus = RateStatus({rateBase: 50000, useHighLevel: 700000, mLow: 10, mHigh: 50});
    }

    modifier factoryOnly() {
        if (msg.sender != address(factory)) revert NotFactory();
        _;
    }

    modifier positionOnly() {
        if (msg.sender != address(marginPositionManager)) revert NotPositionManager();
        _;
    }

    function getReserves() public view returns (uint256 _reserve0, uint256 _reserve1) {
        _reserve0 = reserve0 + mirrorTokenManager.balanceOf(address(this), currency0.toId());
        _reserve1 = reserve1 + mirrorTokenManager.balanceOf(address(this), currency1.toId());
    }

    function ltvParameters() external view returns (uint24 _initialLTV, uint24 _liquidationLTV) {
        _initialLTV = initialLTV;
        _liquidationLTV = liquidationLTV;
    }

    function getBorrowRate(Currency borrowToken) external view returns (uint256) {
        require(borrowToken == currency0 || borrowToken == currency1, "TOKEN_ERROR");
        uint256 tokenReserve = borrowToken == currency0 ? reserve0 : reserve1;
        return _getBorrowRate(borrowToken, tokenReserve);
    }

    // ******************** V2 FUNCTIONS ********************

    // if fee is on, mint liquidity equivalent to 1/(feeTh+1)th of the growth in sqrt(k)
    function _mintFee(uint256 _reserve0, uint256 _reserve1) private returns (bool feeOn) {
        (address feeTo, uint24 feeTh) = IMarginHookFactory(factory).feeParameters();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(_reserve0 * _reserve1);
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply * (rootK - rootKLast);
                    uint256 denominator = rootK * feeTh / 10 ** 3 + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    function mint(address to) internal returns (uint256 liquidity) {
        (uint256 _reserve0, uint256 _reserve1) = getReserves();
        uint256 _totalSupply = totalSupply;
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // The caller has already minted 6909s on the PoolManager to this address
        uint256 balance0 = poolManager.balanceOf(address(this), CurrencyLibrary.toId(currency0));
        uint256 balance1 = poolManager.balanceOf(address(this), CurrencyLibrary.toId(currency1));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity =
                Math.min((amount0 * _totalSupply).unsafeDiv(_reserve0), (amount1 * _totalSupply).unsafeDiv(_reserve1));
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);

        _update(balance0, balance1);
        if (feeOn) kLast = reserve0 * reserve1; // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    function burn(address from, uint256 _liquidity) internal returns (uint256 amount0, uint256 amount1) {
        uint256 balance0 = poolManager.balanceOf(address(this), CurrencyLibrary.toId(currency0));
        uint256 balance1 = poolManager.balanceOf(address(this), CurrencyLibrary.toId(currency1));
        uint256 liquidity = balanceOf[from];
        if (_liquidity < liquidity) {
            liquidity = _liquidity;
        }

        amount0 = (liquidity * balance0).unsafeDiv(totalSupply);
        amount1 = (liquidity * balance1).unsafeDiv(totalSupply);
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurnt();

        _burn(from, liquidity);

        // burn 6909s
        poolManager.burn(address(this), CurrencyLibrary.toId(currency0), amount0);
        poolManager.burn(address(this), CurrencyLibrary.toId(currency1), amount1);
        // transfer token to liquidity from address
        currency0.take(poolManager, from, amount0, false);
        currency1.take(poolManager, from, amount1, false);

        balance0 -= amount0;
        balance1 -= amount1;
        _update(balance0, balance1);
        emit Burn(msg.sender, amount0, amount1, from);
    }

    // force balances to match reserve
    function skim(address to) internal {
        uint256 balance0 = poolManager.balanceOf(address(this), CurrencyLibrary.toId(currency0));
        uint256 balance1 = poolManager.balanceOf(address(this), CurrencyLibrary.toId(currency1));
        if (balance0 > reserve0) {
            currency0.take(poolManager, to, balance0 - reserve0, false);
        }
        if (balance1 > reserve1) {
            currency1.take(poolManager, to, balance1 - reserve1, false);
        }
        _update(balance0, balance1);
    }

    // force reserve to match balances
    function sync() internal {
        uint256 balance0 = poolManager.balanceOf(address(this), CurrencyLibrary.toId(currency0));
        uint256 balance1 = poolManager.balanceOf(address(this), CurrencyLibrary.toId(currency1));
        _update(balance0, balance1);
    }

    // ******************** HOOK FUNCTIONS ********************

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view override returns (bytes4) {
        if (
            sender != factory || key.fee != 0 || key.tickSpacing != 1
                || Currency.unwrap(key.currency0) != Currency.unwrap(currency0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(currency1)
        ) revert InvalidInitialization();
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Facilitate a custom curve via beforeSwap + return delta
    /// @dev input tokens are taken from the PoolManager, creating a debt paid by the swapper
    /// @dev output takens are transferred from the hook to the PoolManager, creating a credit claimed by the swapper
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactInput = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        uint256 specifiedAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 unspecifiedAmount;
        BeforeSwapDelta returnDelta;
        if (exactInput) {
            // in exact-input swaps, the specified token is a debt that gets paid down by the swapper
            // the unspecified token is credited to the PoolManager, that is claimed by the swapper
            unspecifiedAmount = _getAmountOut(params.zeroForOne, specifiedAmount);
            specified.take(poolManager, address(this), specifiedAmount, true);
            unspecified.settle(poolManager, address(this), unspecifiedAmount, true);

            returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount.toInt128());
        } else {
            // exactOutput
            // in exact-output swaps, the unspecified token is a debt that gets paid down by the swapper
            // the specified token is credited to the PoolManager, that is claimed by the swapper
            unspecifiedAmount = _getAmountIn(params.zeroForOne, specifiedAmount);
            unspecified.take(poolManager, address(this), unspecifiedAmount, true);
            specified.settle(poolManager, address(this), specifiedAmount, true);

            returnDelta = toBeforeSwapDelta(-specifiedAmount.toInt128(), unspecifiedAmount.toInt128());
        }
        sync();
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

    function _update(uint256 balance0, uint256 balance1) private {
        if (balance0 > type(uint128).max || balance1 > type(uint128).max) revert BalanceOverflow();
        reserve0 = balance0;
        reserve1 = balance1;
        uint256 timeElapsed = block.timestamp - blockTimestampLast;
        uint256 rate0 = ONE_MILLION + _getBorrowRate(currency0, reserve0) * timeElapsed / YEAR_SECONDS;
        uint256 rate1 = ONE_MILLION + _getBorrowRate(currency1, reserve1) * timeElapsed / YEAR_SECONDS;

        if (rate0CumulativeLast == 0) {
            rate0CumulativeLast = rate0;
        } else {
            rate0CumulativeLast = rate0CumulativeLast * rate0 / ONE_MILLION;
        }

        if (rate1CumulativeLast == 0) {
            rate1CumulativeLast = rate1;
        } else {
            rate1CumulativeLast = rate1CumulativeLast * rate1 / ONE_MILLION;
        }

        blockTimestampLast = block.timestamp;
        emit Sync(reserve0, reserve1);
    }

    // given an input amount of an asset and pair reserve, returns the maximum output amount of the other asset
    function _getAmountOut(bool zeroForOne, uint256 amountIn) internal view returns (uint256 amountOut) {
        require(amountIn > 0, "MarginHook: INSUFFICIENT_INPUT_AMOUNT");

        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        require(reserve0 > 0 && reserve1 > 0, "MarginHook: INSUFFICIENT_LIQUIDITY");

        uint256 amountInWithFee = amountIn * (ONE_MILLION - fee);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * ONE_MILLION) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserve, returns a required input amount of the other asset
    function _getAmountIn(bool zeroForOne, uint256 amountOut) internal view returns (uint256 amountIn) {
        require(amountOut > 0, "MarginHook: INSUFFICIENT_OUTPUT_AMOUNT");

        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        require(reserveIn > 0 && reserveOut > 0, "MarginHook: INSUFFICIENT_LIQUIDITY");

        uint256 numerator = reserveIn * amountOut * ONE_MILLION;
        uint256 denominator = (reserveOut - amountOut) * (ONE_MILLION - fee);
        amountIn = (numerator / denominator) + 1;
    }

    function _getInputOutput(PoolKey calldata key, bool zeroForOne)
        internal
        pure
        returns (Currency input, Currency output)
    {
        (input, output) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
    }

    function _getBorrowRate(Currency borrowToken, uint256 tokenReserve) internal view returns (uint256) {
        uint256 mirrorReserve = mirrorTokenManager.balanceOf(address(this), borrowToken.toId());
        uint256 useLevel = mirrorReserve * ONE_MILLION / (mirrorReserve + tokenReserve);
        if (useLevel >= rateStatus.useHighLevel) {
            return rateStatus.rateBase + rateStatus.useHighLevel * rateStatus.mLow
                + (useLevel - rateStatus.useHighLevel) * rateStatus.mHigh;
        }
        return rateStatus.rateBase + useLevel * rateStatus.mLow;
    }

    // ******************** SELF CALL ********************

    function addLiquidity(uint256 amount0, uint256 amount1) external payable returns (uint256 liquidity) {
        bytes memory result =
            poolManager.unlock(abi.encodeCall(this.handleAddLiquidity, (amount0, amount1, msg.sender)));
        liquidity = abi.decode(result, (uint256));
    }

    /// @dev Handle liquidity addition by taking tokens from the sender and claiming ERC6909 to the hook address
    function handleAddLiquidity(uint256 amount0, uint256 amount1, address sender)
        external
        selfOnly
        returns (bytes memory)
    {
        currency0.settle(poolManager, sender, amount0, false);
        currency0.take(poolManager, address(this), amount0, true);

        currency1.settle(poolManager, sender, amount1, false);
        currency1.take(poolManager, address(this), amount1, true);
        uint256 liquidity = mint(sender);
        return abi.encode(liquidity);
    }

    function removeLiquidity(uint256 _liquidity) external payable returns (uint256 amount0, uint256 amount1) {
        bytes memory result = poolManager.unlock(abi.encodeCall(this.handleRemoveLiquidity, (msg.sender, _liquidity)));
        (amount0, amount1) = abi.decode(result, (uint256, uint256));
    }

    function handleRemoveLiquidity(address to, uint256 _liquidity) external selfOnly returns (bytes memory) {
        (uint256 amount0, uint256 amount1) = burn(to, _liquidity);

        return abi.encode(amount0, amount1);
    }

    // ******************** FACTORY CALL ********************

    function skimReserves(address to) external factoryOnly {
        poolManager.unlock(abi.encodeCall(this.handleSkim, (to)));
    }

    function handleSkim(address to) external selfOnly {
        skim(to);
    }

    // ******************** MARGIN FUNCTIONS ********************

    function borrow(BorrowParams memory params) external positionOnly returns (uint256, BorrowParams memory) {
        require(
            params.borrowToken == Currency.unwrap(currency0) && params.marginToken == Currency.unwrap(currency1)
                || params.borrowToken == Currency.unwrap(currency1) && params.marginToken == Currency.unwrap(currency0),
            "ERROR_HOOK"
        );
        bytes memory result = poolManager.unlock(
            abi.encodeCall(this.handleBorrow, (params.marginSell, params.leverage, params.borrowToken))
        );
        (params.marginTotal, params.borrowAmount) = abi.decode(result, (uint256, uint256));
        uint256 _rateCumulativeLast =
            params.borrowToken == Currency.unwrap(currency0) ? rate0CumulativeLast : rate1CumulativeLast;
        return (_rateCumulativeLast, params);
    }

    function handleBorrow(uint256 marginSell, uint24 leverage, address _borrowToken)
        external
        selfOnly
        returns (bytes memory)
    {
        Currency borrowCurrency = Currency.wrap(_borrowToken);
        require(currency0 == borrowCurrency || currency1 == borrowCurrency, "borrow token err");
        bool zeroForOne = currency0 == borrowCurrency;
        Currency marginCurrency = zeroForOne ? currency1 : currency0;
        uint256 borrowReserves = zeroForOne ? reserve0 : reserve1;
        uint256 marginTotal = marginSell * leverage * initialLTV / (10 ** 6);
        uint256 borrowAmount = _getAmountOut(zeroForOne, marginTotal);
        require(borrowReserves > borrowAmount, "token not enough");
        marginTotal = _getAmountIn(zeroForOne, borrowAmount);
        // send total token
        poolManager.burn(address(this), CurrencyLibrary.toId(marginCurrency), marginTotal);
        marginCurrency.take(poolManager, address(marginPositionManager), marginTotal, false);
        // mint mirror token
        mirrorTokenManager.mint(borrowCurrency.toId(), borrowAmount);
        sync();
        return abi.encode(marginTotal, borrowAmount);
    }

    function repay(address payer, address borrowToken, uint256 repayAmount)
        external
        payable
        positionOnly
        returns (uint256)
    {
        bytes memory result = poolManager.unlock(abi.encodeCall(this.handleRepay, (payer, borrowToken, repayAmount)));
        return abi.decode(result, (uint256));
    }

    function handleRepay(address payer, address borrowToken, uint256 repayAmount)
        external
        selfOnly
        returns (bytes memory)
    {
        // repay borrow
        Currency borrowCurrency = Currency.wrap(borrowToken);
        borrowCurrency.settle(poolManager, payer, repayAmount, false);
        borrowCurrency.take(poolManager, address(this), repayAmount, true);
        // burn mirror token
        mirrorTokenManager.burn(borrowCurrency.toId(), repayAmount);
        sync();
        return abi.encode(repayAmount);
    }
}
