// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

// V4 core
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
// solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {IMarginHookFactory} from "./interfaces/IMarginHookFactory.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";

import {CurrencySettleTake} from "./libraries/CurrencySettleTake.sol";
import {MarginHook} from "./MarginHook.sol";
import {HookParams} from "./types/HookParams.sol";

contract MarginHookFactory is IMarginHookFactory, Owned {
    using CurrencySettleTake for Currency;
    using CurrencyLibrary for Currency;

    error InvalidPermissions();
    error IdenticalAddresses();
    error ZeroAddress();

    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    bytes32 constant TOKEN_0_SLOT = 0x3cad5d3ec16e143a33da68c00099116ef328a882b65607bec5b2431267934a20;
    bytes32 constant TOKEN_1_SLOT = 0x5b610e8e1835afecdd154863369b91f55612defc17933f83f4425533c435a248;
    bytes32 constant FEE_SLOT = 0x833b9f6abf0b529613680afe2a00fa663cc95cbdc47d726d85a044462eabbf02;

    IPoolManager public immutable poolManager;
    IMirrorTokenManager public immutable mirrorTokenManager;
    IMarginPositionManager public immutable marginPositionManager;

    // pairs, always stored token0 -> token1 -> pair, where token0 < token1
    mapping(address => mapping(address => address)) internal _pairs;
    address public feeTo;
    uint24 public feeTh = 3000; // nk: n=1 => 1/2 n=2 => 1/3 ... 5 => 1/6 n=m => 1/(1+m)

    constructor(
        address initialOwner,
        IPoolManager _poolManager,
        IMirrorTokenManager _mirrorTokenManager,
        IMarginPositionManager _marginPositionManager
    ) Owned(initialOwner) {
        poolManager = _poolManager;
        mirrorTokenManager = _mirrorTokenManager;
        marginPositionManager = _marginPositionManager;
    }

    function parameters()
        external
        view
        returns (
            Currency currency0,
            Currency currency1,
            uint24 fee,
            IMirrorTokenManager _mirrorTokenManager,
            IMarginPositionManager _marginPositionManager
        )
    {
        (currency0, currency1, fee) = _getParameters();
        _mirrorTokenManager = mirrorTokenManager;
        _marginPositionManager = marginPositionManager;
    }

    function setFeeTo(address _feeTo) external onlyOwner {
        require(_feeTo != address(0), "ZeroAddress");
        feeTo = _feeTo;
    }

    function setFeeTh(uint24 _feeTh) external onlyOwner {
        require(feeTh > 0, "ZeroNumber");
        feeTh = _feeTh;
    }

    function feeParameters() external view returns (address _feeTo, uint24 _feeTh) {
        _feeTo = feeTo;
        _feeTh = feeTh;
    }

    function getHookPair(address tokenA, address tokenB) external view returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _pairs[token0][token1];
    }

    function _setParameters(address token0, address token1, uint24 fee) internal {
        assembly {
            tstore(TOKEN_0_SLOT, token0)
            tstore(TOKEN_1_SLOT, token1)
            tstore(FEE_SLOT, fee)
        }
    }

    function _getParameters() internal view returns (Currency currency0, Currency currency1, uint24 fee) {
        assembly {
            currency0 := tload(TOKEN_0_SLOT)
            currency1 := tload(TOKEN_1_SLOT)
            fee := tload(FEE_SLOT)
        }
    }

    function createHook(HookParams calldata params) external returns (IHooks hook) {
        // Validate tokenA and tokenB are not the same address
        if (params.tokenA == params.tokenB) revert IdenticalAddresses();

        // Validate tokenA and tokenB both are not the zero address
        if (params.tokenA == address(0) && params.tokenB == address(0)) revert ZeroAddress();

        // sort the tokens
        (address token0, address token1) =
            params.tokenA < params.tokenB ? (params.tokenA, params.tokenB) : (params.tokenB, params.tokenA);
        // Validate the pair does not already exist
        if (_pairs[token0][token1] != address(0)) revert PairExists();

        // write to transient storage: token0, token1
        _setParameters(token0, token1, params.fee);

        // deploy hook (expect callback to parameters)
        hook = new MarginHook{salt: params.salt}(poolManager, params.name, params.symbol);
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
