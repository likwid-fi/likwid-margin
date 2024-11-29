// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginHookManager} from "../src/MarginHookManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {HookParams} from "../src/types/HookParams.sol";
import {HookStatus} from "../src/types/HookStatus.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../src/types/LiquidityParams.sol";
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

import {HookMiner} from "./utils/HookMiner.sol";

contract MarginHookManagerTest is Test {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 public constant ONE_BILLION = 10 ** 9;
    uint256 public constant YEAR_SECONDS = 365 * 24 * 3600;

    MarginHookManager hookManager;

    PoolKey key;
    PoolKey nativeKey;

    MockERC20 tokenA;
    MockERC20 tokenB;
    address user;

    Currency currency0;
    Currency currency1;
    PoolManager manager;
    MirrorTokenManager mirrorTokenManager;
    MarginPositionManager marginPositionManager;
    MarginRouter swapRouter;

    function parameters() external view returns (Currency, Currency, IPoolManager) {
        return (currency0, currency1, manager);
    }

    function deployMintAndApprove2Currencies() internal {
        tokenA = new MockERC20("TESTA", "TESTA", 18);
        Currency currencyA = Currency.wrap(address(tokenA));

        tokenB = new MockERC20("TESTB", "TESTB", 18);
        Currency currencyB = Currency.wrap(address(tokenB));

        (currency0, currency1) = address(tokenA) < address(tokenB) ? (currencyA, currencyB) : (currencyB, currencyA);

        // Deploy the hook to an address with the correct flags
        uint160 flags =
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

        bytes memory constructorArgs = abi.encode(user, manager, mirrorTokenManager, marginPositionManager); //Add all the necessary constructor arguments from the hook
        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(MarginHookManager).creationCode, constructorArgs);

        hookManager = new MarginHookManager{salt: salt}(user, manager, mirrorTokenManager, marginPositionManager);
        assertEq(address(hookManager), hookAddress);
        tokenA.mint(address(this), 2 ** 255);
        tokenB.mint(address(this), 2 ** 255);

        tokenA.transfer(user, 10e18);
        tokenB.transfer(user, 10e18);

        tokenA.approve(address(hookManager), type(uint256).max);
        tokenB.approve(address(hookManager), type(uint256).max);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);

        key = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 1, hooks: hookManager});
        nativeKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: currency1,
            fee: 0,
            tickSpacing: 1,
            hooks: hookManager
        });

        hookManager.initialize(key);
        hookManager.initialize(nativeKey);
    }

    function setUp() public {
        user = vm.addr(2);
        (bool success,) = user.call{value: 10e18}("");
        assertTrue(success);
        manager = new PoolManager(user);
        mirrorTokenManager = new MirrorTokenManager(user);
        marginPositionManager = new MarginPositionManager(user);
        deployMintAndApprove2Currencies();
        vm.prank(user);
        marginPositionManager.setHook(address(hookManager));
        swapRouter = new MarginRouter(user, manager, hookManager);
    }

    receive() external payable {}

    function test_hook_liquidity_tokens() public {
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: key.toId(),
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            to: address(this),
            deadline: type(uint256).max
        });
        hookManager.addLiquidity(params);
        uint256 uPoolId = uint256(PoolId.unwrap(key.toId()));
        uint256 liquidity = hookManager.balanceOf(address(this), uPoolId);
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(key.toId());
        assertEq(_reserves0, _reserves1);
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: key.toId(), liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = hookManager.balanceOf(address(this), uPoolId);
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }

    function test_hook_margin_tokens() public {
        test_hook_liquidity_tokens();
        vm.startPrank(user);
        uint256 rate = hookManager.getBorrowRate(nativeKey.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        tokenA.approve(address(marginPositionManager), payValue);
        tokenB.approve(address(marginPositionManager), payValue);
        MarginParams memory params = MarginParams({
            poolId: key.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin(params);
        console.log(
            "hookManager.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );

        tokenA.approve(address(marginPositionManager), payValue);
        tokenB.approve(address(marginPositionManager), payValue);
        params = MarginParams({
            poolId: key.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin(params);
        console.log(
            "hookManager.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );
        vm.stopPrank();
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(key.toId());
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        HookStatus memory _status = hookManager.getStatus(key.toId());
        console.log("reserve0:%s,reserve1:%s", uint256(_status.reserve0), uint256(_status.reserve1));
        console.log(
            "mirrorReserve0:%s,mirrorReserve1:%s", uint256(_status.mirrorReserve0), uint256(_status.mirrorReserve1)
        );
    }

    function test_hook_swap_tokens() public {
        test_hook_liquidity_tokens();
        vm.startPrank(user);
        uint256 amountIn = 0.0123 ether;
        // swap
        uint256 balance0 = manager.balanceOf(address(hookManager), uint160(address(tokenA)));
        uint256 balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        console.log("before swap tokenA:%s,tokenB:%s", tokenA.balanceOf(user), tokenB.balanceOf(user));
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            poolId: key.toId(),
            zeroForOne: true,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        tokenA.approve(address(swapRouter), amountIn);
        tokenB.approve(address(swapRouter), amountIn);
        swapRouter.exactInput(swapParams);
        console.log("swapRouter.balance:%s", manager.balanceOf(address(swapRouter), 0));
        console.log("after swap tokenA:%s,tokenB:%s", tokenA.balanceOf(user), tokenB.balanceOf(user));
        balance0 = manager.balanceOf(address(hookManager), uint160(address(tokenA)));
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        vm.stopPrank();
    }

    function test_hook_repay_tokens() public {
        test_hook_margin_tokens();
        vm.startPrank(user);
        uint256 positionId = marginPositionManager.getPositionId(key.toId(), false, user);
        assertGt(positionId, 0);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log("before repay positionId:%s,position.borrowAmount:%s", positionId, position.borrowAmount);
        console.log("before repay tokenA.balance:%s tokenB.balance:%s", tokenA.balanceOf(user), tokenB.balanceOf(user));
        uint256 repay = 0.01 ether;
        tokenB.approve(address(hookManager), repay);
        marginPositionManager.repay(positionId, repay, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        console.log("after repay tokenA.balance:%s tokenB.balance:%s", tokenA.balanceOf(user), tokenB.balanceOf(user));
        console.log("after repay positionId:%s,position.borrowAmount:%s", positionId, newPosition.borrowAmount);
        assertEq(position.borrowAmount - newPosition.borrowAmount, repay);
        vm.stopPrank();
    }

    function test_hook_liquidity_v2() public {
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: key.toId(),
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            to: address(this),
            deadline: type(uint256).max
        });
        hookManager.addLiquidity(params);
        uint256 uPoolId = uint256(PoolId.unwrap(key.toId()));
        uint256 liquidity = hookManager.balanceOf(address(this), uPoolId);
        (uint256 _reserves0, uint256 _reserves1) = hookManager.getReserves(key.toId());
        assertEq(_reserves0, _reserves1);
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        RemoveLiquidityParams memory removeParams =
            RemoveLiquidityParams({poolId: key.toId(), liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        uint256 liquidityHalf = hookManager.balanceOf(address(this), uPoolId);
        assertEq(liquidityHalf, liquidity - liquidity / 2);

        params = AddLiquidityParams({
            poolId: nativeKey.toId(),
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            to: address(this),
            deadline: type(uint256).max
        });
        hookManager.addLiquidity{value: 1 ether}(params);
        uPoolId = uint256(PoolId.unwrap(nativeKey.toId()));
        liquidity = hookManager.balanceOf(address(this), uPoolId);
        (_reserves0, _reserves1) = hookManager.getReserves(nativeKey.toId());
        assertEq(_reserves0, _reserves1);
        console.log("_reserves0:%s,_reserves1:%s", _reserves0, _reserves1);
        removeParams =
            RemoveLiquidityParams({poolId: nativeKey.toId(), liquidity: liquidity / 2, deadline: type(uint256).max});
        hookManager.removeLiquidity(removeParams);
        liquidityHalf = hookManager.balanceOf(address(this), uPoolId);
        assertEq(liquidityHalf, liquidity - liquidity / 2);
    }

    function test_hook_swap_native() public {
        test_hook_liquidity_v2();
        vm.startPrank(user);
        uint256 amountIn = 0.0123 ether;
        // swap
        uint256 balance0 = manager.balanceOf(address(hookManager), 0);
        uint256 balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        console.log("before swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            poolId: nativeKey.toId(),
            zeroForOne: true,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        swapRouter.exactInput{value: amountIn}(swapParams);
        console.log("swapRouter.balance:%s", manager.balanceOf(address(swapRouter), 0));
        console.log("after swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        balance0 = manager.balanceOf(address(hookManager), 0);
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        // token => native
        console.log("before swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        swapParams = MarginRouter.SwapParams({
            poolId: nativeKey.toId(),
            zeroForOne: false,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        tokenB.approve(address(swapRouter), amountIn);
        swapRouter.exactInput(swapParams);
        console.log("swapRouter.balance:%s", manager.balanceOf(address(swapRouter), 0));
        console.log("after swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        balance0 = manager.balanceOf(address(hookManager), 0);
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        vm.stopPrank();
    }

    function test_hook_swap_native_out() public {
        test_hook_liquidity_v2();
        vm.startPrank(user);
        uint256 amountOut = 0.0123 ether;
        bool zeroForOne = true;
        // swap
        uint256 amountIn = hookManager.getAmountIn(nativeKey.toId(), zeroForOne, amountOut);
        uint256 balance0 = manager.balanceOf(address(hookManager), 0);
        uint256 balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        console.log("before swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            poolId: nativeKey.toId(),
            zeroForOne: zeroForOne,
            to: user,
            amountIn: 0,
            amountOut: amountOut,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        swapRouter.exactOutput{value: amountIn}(swapParams);
        console.log("swapRouter.balance:%s", manager.balanceOf(address(swapRouter), 0));
        console.log("after swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        balance0 = manager.balanceOf(address(hookManager), 0);
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);

        // token => native
        zeroForOne = false;
        tokenB.approve(address(swapRouter), amountIn);
        // swap
        amountIn = hookManager.getAmountIn(nativeKey.toId(), zeroForOne, amountOut);
        balance0 = manager.balanceOf(address(hookManager), 0);
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        console.log("before swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        swapParams = MarginRouter.SwapParams({
            poolId: nativeKey.toId(),
            zeroForOne: zeroForOne,
            to: user,
            amountIn: 0,
            amountOut: amountOut,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        swapRouter.exactOutput(swapParams);
        console.log("swapRouter.balance:%s", manager.balanceOf(address(swapRouter), 0));
        console.log("after swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        balance0 = manager.balanceOf(address(hookManager), 0);
        balance1 = manager.balanceOf(address(hookManager), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        vm.stopPrank();
    }

    function test_hook_margin() public {
        test_hook_liquidity_v2();
        vm.startPrank(user);
        tokenB.approve(address(hookManager), 1e18);
        uint256 rate = hookManager.getBorrowRate(nativeKey.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01 ether;
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "hookManager.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );
        rate = hookManager.getBorrowRate(nativeKey.toId(), false);
        uint256 rateLast = hookManager.getBorrowRateCumulativeLast(nativeKey.toId(), false);
        console.log("rate:%s,rateLast:%s", rate, rateLast);
        vm.warp(3600 * 10);
        uint256 timeElapsed = (3600 * 10 - 1) * 10 ** 3;
        uint256 rateLastX = (ONE_BILLION + rate * timeElapsed / YEAR_SECONDS) * rateLast / ONE_BILLION;
        console.log("timeElapsed:%s,rateLastX:%s", timeElapsed, rateLastX);
        uint256 borrowAmountLast = borrowAmount;
        payValue = 0.02e18;
        params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        position = marginPositionManager.getPosition(positionId);
        uint256 borrowAmountAll = borrowAmount + borrowAmountLast * rateLastX / rateLast;
        assertEq(position.borrowAmount / 100, borrowAmountAll / 100);
        console.log("positionId:%s,position.borrowAmount:%s,all:%s", positionId, position.borrowAmount, borrowAmountAll);

        vm.warp(3600 * 20);
        rate = hookManager.getBorrowRate(nativeKey.toId(), false);
        timeElapsed = (3600 * 10) * 10 ** 3;
        rateLast = rateLastX;
        rateLastX = (ONE_BILLION + rate * timeElapsed / YEAR_SECONDS) * rateLast / ONE_BILLION;
        console.log("timeElapsed:%s,rateLast:%s,rateLastX:%s", timeElapsed, rateLast, rateLastX);

        payValue = 0.02e18;
        params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        position = marginPositionManager.getPosition(positionId);
        borrowAmountAll = borrowAmount + borrowAmountAll * rateLastX / rateLast;
        assertEq(position.borrowAmount / 100, borrowAmountAll / 100);
        console.log("positionId:%s,position.borrowAmount:%s,all:%s", positionId, position.borrowAmount, borrowAmountAll);
        vm.stopPrank();
    }

    function test_hook_repay() public {
        test_hook_margin();
        vm.startPrank(user);
        uint256 positionId = marginPositionManager.getPositionId(nativeKey.toId(), false, user);
        assertGt(positionId, 0);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        uint256 userBalance = user.balance;
        console.log("before repay positionId:%s,position.borrowAmount:%s", positionId, position.borrowAmount);
        console.log("before repay balance:%s tokenB.balance:%s", user.balance, tokenB.balanceOf(user));
        uint256 repay = 0.01 ether;
        tokenB.approve(address(hookManager), repay);
        marginPositionManager.repay(positionId, repay, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        console.log("after repay balance:%s tokenB.balance:%s", user.balance, tokenB.balanceOf(user));
        console.log("after repay positionId:%s,position.borrowAmount:%s", positionId, newPosition.borrowAmount);
        assertEq(position.borrowAmount - newPosition.borrowAmount, repay);
        assertEq(position.marginTotal - newPosition.marginTotal, user.balance - userBalance);
        vm.stopPrank();
    }

    function test_hook_liquidate() public {
        test_hook_liquidity_v2();
        vm.startPrank(user);
        tokenB.approve(address(hookManager), 1e18);
        uint256 rate = hookManager.getBorrowRate(nativeKey.toId(), false);
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.1 ether;
        MarginParams memory params = MarginParams({
            poolId: nativeKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            marginTotal: 0,
            borrowAmount: 0,
            borrowMinAmount: 0,
            recipient: user,
            deadline: block.timestamp + 1000
        });

        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        console.log(
            "hookManager.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        console.log(
            "positionId:%s,position.borrowAmount:%s,rateCumulativeLast:%s",
            positionId,
            position.borrowAmount,
            position.rateCumulativeLast
        );

        positionId = marginPositionManager.getPositionId(nativeKey.toId(), false, user);
        assertGt(positionId, 0);
        position = marginPositionManager.getPosition(positionId);
        (bool liquidated, uint256 releaseAmount) = marginPositionManager.checkLiquidate(positionId);
        console.log("liquidated:%s,releaseAmount:%s", liquidated, releaseAmount);
        uint256 amountIn = 0.1 ether;
        while (!liquidated) {
            MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                poolId: nativeKey.toId(),
                zeroForOne: true,
                to: user,
                amountIn: amountIn,
                amountOut: 0,
                amountOutMin: 0,
                deadline: type(uint256).max
            });
            swapRouter.exactInput{value: amountIn}(swapParams);
            (liquidated, releaseAmount) = marginPositionManager.checkLiquidate(positionId);
            console.log("releaseAmount:%s", releaseAmount);
        }
        console.log(
            "before liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        marginPositionManager.liquidate(positionId);
        position = marginPositionManager.getPosition(positionId);
        console.log(
            "after liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(hookManager).balance,
            address(marginPositionManager).balance
        );
        vm.stopPrank();
    }
}
