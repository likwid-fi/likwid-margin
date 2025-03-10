// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginHook} from "../../src/MarginHook.sol";
import {LendingPoolManager} from "../../src/LendingPoolManager.sol";
import {PairPoolManager} from "../../src/PairPoolManager.sol";
import {MirrorTokenManager} from "../../src/MirrorTokenManager.sol";
import {MarginLiquidity} from "../../src/MarginLiquidity.sol";
import {MarginPositionManager} from "../../src/MarginPositionManager.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {MarginOracle} from "../../src/MarginOracle.sol";
import {MarginFees} from "../../src/MarginFees.sol";
import {MarginChecker} from "../../src/MarginChecker.sol";
import {PoolStatus} from "../../src/types/PoolStatus.sol";
import {MarginParams} from "../../src/types/MarginParams.sol";
import {MarginPosition} from "../../src/types/MarginPosition.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../../src/types/LiquidityParams.sol";
import {MarginPosition} from "../../src/types/MarginPosition.sol";
import {LiquidityLevel} from "../../src/libraries/LiquidityLevel.sol";
// Solmate
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// Forge
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
// V4
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

import {HookMiner} from "./HookMiner.sol";
import {EIP20NonStandardThrowHarness} from "../mocks/EIP20NonStandardThrowHarness.sol";

contract DeployHelper is Test {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 public constant ONE_BILLION = 10 ** 9;
    uint256 public constant YEAR_SECONDS = 365 * 24 * 3600;

    PairPoolManager pairPoolManager;

    PoolKey key;
    PoolKey usdtKey;
    PoolKey nativeKey;

    MockERC20 tokenA;
    MockERC20 tokenB;
    EIP20NonStandardThrowHarness tokenUSDT;

    PoolManager manager;
    MirrorTokenManager mirrorTokenManager;
    LendingPoolManager lendingPoolManager;
    MarginLiquidity marginLiquidity;
    MarginPositionManager marginPositionManager;
    MarginRouter swapRouter;
    MarginOracle marginOracle;
    MarginFees marginFees;
    MarginChecker marginChecker;

    function deployMintAndApprove2Currencies() internal {
        tokenA = new MockERC20("TESTA", "TESTA", 18);
        Currency currencyA = Currency.wrap(address(tokenA));

        tokenB = new MockERC20("TESTB", "TESTB", 18);
        Currency currencyB = Currency.wrap(address(tokenB));

        tokenUSDT = new EIP20NonStandardThrowHarness(UINT256_MAX, "TESTA", 18, "TESTA");
        Currency currencyUSDT = Currency.wrap(address(tokenUSDT));

        (Currency currency0, Currency currency1) =
            address(tokenA) < address(tokenB) ? (currencyA, currencyB) : (currencyB, currencyA);

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        pairPoolManager = new PairPoolManager(
            address(this), manager, mirrorTokenManager, lendingPoolManager, marginLiquidity, marginFees
        );

        marginLiquidity.addPoolManager(address(pairPoolManager));
        mirrorTokenManager.addPoolManger(address(pairPoolManager));

        bytes memory constructorArgs = abi.encode(address(this), manager, address(pairPoolManager)); //Add all the necessary constructor arguments from the hook
        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(MarginHook).creationCode, constructorArgs);

        MarginHook hookManager = new MarginHook{salt: salt}(address(this), manager, pairPoolManager);
        assertEq(address(hookManager), hookAddress);
        pairPoolManager.setHooks(hookManager);

        tokenA.mint(address(this), 2 ** 255);
        tokenB.mint(address(this), 2 ** 255);

        tokenA.approve(address(pairPoolManager), type(uint256).max);
        tokenB.approve(address(pairPoolManager), type(uint256).max);
        tokenUSDT.approve(address(pairPoolManager), type(uint256).max);
        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 1, hooks: hookManager});
        nativeKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: currencyB,
            fee: 3000,
            tickSpacing: 1,
            hooks: hookManager
        });

        usdtKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: currencyUSDT,
            fee: 3000,
            tickSpacing: 1,
            hooks: hookManager
        });

        manager.initialize(key, SQRT_RATIO_1_1);
        manager.initialize(nativeKey, SQRT_RATIO_1_1);
        manager.initialize(usdtKey, SQRT_RATIO_1_1);

        marginChecker = new MarginChecker(address(this));
        marginPositionManager = new MarginPositionManager(address(this), pairPoolManager, marginChecker);
        tokenA.approve(address(marginPositionManager), type(uint256).max);
        tokenB.approve(address(marginPositionManager), type(uint256).max);
        tokenUSDT.approve(address(marginPositionManager), type(uint256).max);
        pairPoolManager.addPositionManager(address(marginPositionManager));
        pairPoolManager.setMarginOracle(address(marginOracle));
        lendingPoolManager.setPairPoolManger(pairPoolManager);
        swapRouter = new MarginRouter(address(this), manager, pairPoolManager);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenUSDT.approve(address(swapRouter), type(uint256).max);
    }

    function deployHookAndRouter() internal {
        manager = new PoolManager(address(this));
        mirrorTokenManager = new MirrorTokenManager(address(this));
        lendingPoolManager = new LendingPoolManager(address(this), manager, mirrorTokenManager);
        marginFees = new MarginFees(address(this));
        marginLiquidity = new MarginLiquidity(address(this));
        marginOracle = new MarginOracle();
        deployMintAndApprove2Currencies();
    }

    function initPoolLiquidity() internal {
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: key.toId(),
            level: 4,
            amount0: 1e18,
            amount1: 1e18,
            to: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity(params);
        params = AddLiquidityParams({
            poolId: nativeKey.toId(),
            level: 4,
            amount0: 1 ether,
            amount1: 100 ether,
            to: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: 1 ether}(params);
        params = AddLiquidityParams({
            poolId: usdtKey.toId(),
            level: 4,
            amount0: 1 ether,
            amount1: 100 ether,
            to: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: 1 ether}(params);
    }

    receive() external payable {}
}
