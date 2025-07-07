// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginHook} from "../../src/MarginHook.sol";
import {LendingPoolManager} from "../../src/LendingPoolManager.sol";
import {PairPoolManager} from "../../src/PairPoolManager.sol";
import {PoolStatusManager} from "../../src/PoolStatusManager.sol";
import {MirrorTokenManager} from "../../src/MirrorTokenManager.sol";
import {MarginLiquidity} from "../../src/MarginLiquidity.sol";
import {MarginPositionManager} from "../../src/MarginPositionManager.sol";
import {MarginRouter} from "../../src/MarginRouter.sol";
import {MarginFees} from "../../src/MarginFees.sol";
import {MarginChecker} from "../../src/MarginChecker.sol";
import {PoolStatus} from "../../src/types/PoolStatus.sol";
import {MarginParams} from "../../src/types/MarginParams.sol";
import {MarginPosition} from "../../src/types/MarginPosition.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../../src/types/LiquidityParams.sol";
import {MarginPosition} from "../../src/types/MarginPosition.sol";
// Solmate
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// Forge
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
// V4
import {LikwidVault} from "likwid-v2-core/LikwidVault.sol";
import {Hooks} from "likwid-v2-core/libraries/Hooks.sol";
import {IHooks} from "likwid-v2-core/interfaces/IHooks.sol";
import {IPoolManager} from "likwid-v2-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "likwid-v2-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "likwid-v2-core/types/Currency.sol";
import {PoolKey} from "likwid-v2-core/types/PoolKey.sol";

import {BalanceDelta, BalanceDeltaLibrary} from "likwid-v2-core/types/BalanceDelta.sol";

import {HookMiner} from "./HookMiner.sol";
import {EIP20NonStandardThrowHarness} from "../mocks/EIP20NonStandardThrowHarness.sol";

contract DeployHelper is Test {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 public constant ONE_TRILLION = 10 ** 12;
    uint256 public constant TRILLION_YEAR_SECONDS = ONE_TRILLION * 365 * 24 * 3600;

    PairPoolManager pairPoolManager;

    error MessageError();

    PoolKey tokensKey;
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
    MarginFees marginFees;
    MarginChecker marginChecker;
    PoolStatusManager poolStatusManager;

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

        pairPoolManager =
            new PairPoolManager(address(this), manager, mirrorTokenManager, lendingPoolManager, marginLiquidity);

        poolStatusManager = new PoolStatusManager(
            address(this), manager, mirrorTokenManager, lendingPoolManager, marginLiquidity, pairPoolManager, marginFees
        );

        pairPoolManager.setStatusManager(poolStatusManager);

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
        tokensKey = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 1, hooks: hookManager});
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

        manager.initialize(tokensKey, SQRT_RATIO_1_1);
        manager.initialize(nativeKey, SQRT_RATIO_1_1);
        manager.initialize(usdtKey, SQRT_RATIO_1_1);

        marginChecker = new MarginChecker(address(this));
        marginPositionManager = new MarginPositionManager(address(this), pairPoolManager, marginChecker);
        tokenA.approve(address(marginPositionManager), type(uint256).max);
        tokenB.approve(address(marginPositionManager), type(uint256).max);
        tokenUSDT.approve(address(marginPositionManager), type(uint256).max);
        pairPoolManager.addPositionManager(address(marginPositionManager));
        lendingPoolManager.setPairPoolManger(pairPoolManager);
        swapRouter = new MarginRouter(address(this), manager, pairPoolManager);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        tokenUSDT.approve(address(swapRouter), type(uint256).max);

        marginLiquidity.addPoolManager(address(pairPoolManager));
        mirrorTokenManager.addPoolManager(address(pairPoolManager));

        // Initialize the margin liquidity
        marginLiquidity.setStageSize(0);
        marginLiquidity.setStageDuration(0);
    }

    function deployHookAndRouter() internal {
        manager = new PoolManager(address(this));
        mirrorTokenManager = new MirrorTokenManager(address(this));
        lendingPoolManager = new LendingPoolManager(address(this), manager, mirrorTokenManager);
        marginFees = new MarginFees(address(this));
        marginLiquidity = new MarginLiquidity(address(this));

        deployMintAndApprove2Currencies();
    }

    function initNativeKey() internal {
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: nativeKey.toId(),
            amount0: 1 ether,
            amount1: 10 ether,
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: 1 ether}(params);
    }

    function initTokensKey() internal {
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: tokensKey.toId(),
            amount0: 10 ether,
            amount1: 10 ether,
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: 1 ether}(params);
    }

    function initUSDTKey() internal {
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: usdtKey.toId(),
            amount0: 1 ether,
            amount1: 100 ether,
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: 1 ether}(params);
    }

    function initPoolLiquidity() internal {
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: tokensKey.toId(),
            amount0: 1e18,
            amount1: 1e18,
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity(params);
        params = AddLiquidityParams({
            poolId: nativeKey.toId(),
            amount0: 1 ether,
            amount1: 100 ether,
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: 1 ether}(params);
        params = AddLiquidityParams({
            poolId: usdtKey.toId(),
            amount0: 1 ether,
            amount1: 100 ether,
            amount0Min: 0,
            amount1Min: 0,
            source: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: 1 ether}(params);
    }

    function printPoolStatus(PoolStatus memory status) internal pure {
        console.logBytes32(PoolId.unwrap(status.key.toId()));
        console.log("status.realReserve0:", status.realReserve0);
        console.log("status.realReserve1:", status.realReserve1);
        console.log("status.mirrorReserve0:", status.mirrorReserve0);
        console.log("status.mirrorReserve1:", status.mirrorReserve1);
        console.log("status.lendingRealReserve0:", status.lendingRealReserve0);
        console.log("status.lendingRealReserve1:", status.lendingRealReserve1);
        console.log("status.lendingMirrorReserve0:", status.lendingMirrorReserve0);
        console.log("status.lendingMirrorReserve1:", status.lendingMirrorReserve1);
        console.log("status.truncatedReserve0:", status.truncatedReserve0);
        console.log("status.truncatedReserve1:", status.truncatedReserve1);
    }

    function nativeKeyBalance(string memory message) internal view {
        uint256 balanceBefore0 = manager.balanceOf(address(pairPoolManager), nativeKey.currency0.toId());
        uint256 balanceBefore1 = manager.balanceOf(address(pairPoolManager), nativeKey.currency1.toId());
        uint256 fees0 = poolStatusManager.protocolFeesAccrued(nativeKey.currency0);
        uint256 fees1 = poolStatusManager.protocolFeesAccrued(nativeKey.currency1);
        PoolStatus memory status = pairPoolManager.getStatus(nativeKey.toId());
        uint256 realReserveBefore0 = status.realReserve0;
        uint256 realReserveBefore1 = status.realReserve1;
        assertEq(balanceBefore0, realReserveBefore0 + fees0, string.concat(message, " currency0 is not balance"));
        assertEq(balanceBefore1, realReserveBefore1 + fees1, string.concat(message, " currency1 is not balance"));
        assertGt(balanceBefore0, 0);
        assertGt(balanceBefore1, 0);
    }

    receive() external payable {}
}
