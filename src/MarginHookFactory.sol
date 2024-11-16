// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// V4 core
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
// Local
import {IMarginHookFactory} from "./interfaces/IMarginHookFactory.sol";
import {CurrencySettleTake} from "./libraries/CurrencySettleTake.sol";
import {MarginHook} from "./MarginHook.sol";

contract MarginHookFactory is IMarginHookFactory {
    using CurrencySettleTake for Currency;
    using CurrencyLibrary for Currency;

    error InvalidPermissions();
    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();
    error PairNotExists();

    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    bytes32 constant TOKEN_0_SLOT = 0x3cad5d3ec16e143a33da68c00099116ef328a882b65607bec5b2431267934a20;
    bytes32 constant TOKEN_1_SLOT = 0x5b610e8e1835afecdd154863369b91f55612defc17933f83f4425533c435a248;

    IPoolManager public immutable poolManager;

    // pairs, always stored token0 -> token1 -> pair, where token0 < token1
    mapping(address => mapping(address => address)) internal _pairs;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function parameters() external view returns (Currency currency0, Currency currency1, IPoolManager _poolManager) {
        (currency0, currency1) = _getParameters();
        _poolManager = poolManager;
    }

    function getPair(address tokenA, address tokenB) external view returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _pairs[token0][token1];
    }

    function _setParameters(address token0, address token1) internal {
        assembly {
            tstore(TOKEN_0_SLOT, token0)
            tstore(TOKEN_1_SLOT, token1)
        }
    }

    function _getParameters() internal view returns (Currency currency0, Currency currency1) {
        assembly {
            currency0 := tload(TOKEN_0_SLOT)
            currency1 := tload(TOKEN_1_SLOT)
        }
    }

    function createHook(bytes32 salt, string memory _name, string memory _symbol, address tokenA, address tokenB)
        external
        returns (IHooks hook)
    {
        // Validate tokenA and tokenB are not the same address
        if (tokenA == tokenB) revert IdenticalAddresses();

        // Validate tokenA and tokenB are not the zero address
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();

        // sort the tokens
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // Validate the pair does not already exist
        if (_pairs[token0][token1] != address(0)) revert PairExists();

        // write to transient storage: token0, token1
        _setParameters(token0, token1);

        // deploy hook (expect callback to parameters)
        hook = new MarginHook{salt: salt}(poolManager, _name, _symbol);
        address hookAddress = address(hook);

        // only write the tokens in order
        _pairs[token0][token1] = hookAddress;

        // call v4 initialize pool
        // fee and tickspacing are meaningless, they're set to 0 and 1 for all V2 Pair Hooks
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: 1,
            hooks: hook
        });

        poolManager.initialize(key, SQRT_RATIO_1_1);

        emit HookCreated(token0, token1, hookAddress);
    }
}
