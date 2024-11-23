// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {MarginHook} from "../src/MarginHook.sol";
import {MarginHookFactory} from "../src/MarginHookFactory.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {HookParams} from "../src/types/HookParams.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {LiquidityParams} from "../src/types/LiquidityParams.sol";
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
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

import {HookMiner} from "./utils/HookMiner.sol";

contract MarginHookTest is Test {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 public constant ONE_BILLION = 10 ** 9;
    uint256 public constant YEAR_SECONDS = 365 * 24 * 3600;

    MarginHook hook;
    MarginHook nativeHook;

    // PoolKey key;
    // PoolKey nativeKey;

    MockERC20 tokenB;
    address user;

    Currency currency0;
    Currency currency1;
    PoolManager manager;
    MarginHookFactory factory;
    MirrorTokenManager mirrorTokenManager;
    MarginPositionManager marginPositionManager;
    MarginRouter swapRouter;

    function parameters() external view returns (Currency, Currency, IPoolManager) {
        return (currency0, currency1, manager);
    }

    function deployMintAndApprove2Currencies() internal {
        MockERC20 tokenA = new MockERC20("TESTA", "TESTA", 18);
        Currency currencyA = Currency.wrap(address(tokenA));

        tokenB = new MockERC20("TESTB", "TESTB", 18);
        Currency currencyB = Currency.wrap(address(tokenB));

        (currency0, currency1) = address(tokenA) < address(tokenB) ? (currencyA, currencyB) : (currencyB, currencyA);

        // Deploy the hook to an address with the correct flags
        uint160 flags =
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

        bytes memory constructorArgs = abi.encode(user, manager, "TEST HOOK", "TH"); //Add all the necessary constructor arguments from the hook
        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(factory), flags, type(MarginHook).creationCode, constructorArgs);
        HookParams memory params = HookParams({
            salt: salt,
            name: "TEST HOOK",
            symbol: "TH",
            tokenA: address(tokenA),
            tokenB: address(tokenB),
            fee: 3000,
            marginFee: 15000
        });
        IHooks createHookAddress = factory.createHook(params);
        // deployCodeTo("MarginHook.sol:MarginHook", constructorArgs, hookAddress);
        assertEq(address(createHookAddress), hookAddress);
        console.log("createHookAddress:%s, hookAddress:%s", address(createHookAddress), hookAddress);
        hook = MarginHook(hookAddress);

        constructorArgs = abi.encode(user, manager, "TEST NATIVE HOOK", "TNH");
        (hookAddress, salt) = HookMiner.find(address(factory), flags, type(MarginHook).creationCode, constructorArgs);
        params = HookParams({
            salt: salt,
            name: "TEST NATIVE HOOK",
            symbol: "TNH",
            tokenA: address(0),
            tokenB: address(tokenB),
            fee: 3000,
            marginFee: 15000
        });
        createHookAddress = factory.createHook(params);
        assertEq(address(createHookAddress), hookAddress);
        console.log("native createHookAddress:%s, hookAddress:%s", address(createHookAddress), hookAddress);
        nativeHook = MarginHook(hookAddress);

        tokenA.mint(address(this), 2 ** 255);
        tokenB.mint(address(this), 2 ** 255);

        tokenB.transfer(user, 10e18);

        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);
        tokenB.approve(address(nativeHook), type(uint256).max);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
    }

    function setUp() public {
        user = vm.addr(2);
        (bool success,) = user.call{value: 10e18}("");
        assertTrue(success);
        manager = new PoolManager(user);
        mirrorTokenManager = new MirrorTokenManager(user);
        marginPositionManager = new MarginPositionManager(user);
        factory = new MarginHookFactory(user, manager, mirrorTokenManager, marginPositionManager);
        vm.prank(user);
        // marginPositionManager.setFactory(address(factory));

        deployMintAndApprove2Currencies();

        //swapRouter = new MarginRouter(user, manager, factory);
    }

    function test_hook_liquidity() public {
        LiquidityParams memory params = LiquidityParams({
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            recipient: address(this),
            deadline: type(uint256).max
        });
        hook.addLiquidity(params);
        uint256 liquidity = hook.balanceOf(address(this));
        (uint256 _reserves0, uint256 _reserves1) = hook.getReserves();
        assertEq(_reserves0, _reserves1);
        hook.removeLiquidity(liquidity / 2);
        uint256 liquidityHelf = hook.balanceOf(address(this));
        assertEq(liquidityHelf, liquidity - liquidity / 2);
    }

    function test_hook_native_liquidity() public {
        // address(this) could not receive native.
        vm.startPrank(user);
        tokenB.approve(address(nativeHook), 1e18);
        uint256 balanceBBefore = tokenB.balanceOf(user);
        LiquidityParams memory params = LiquidityParams({
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            recipient: user,
            deadline: type(uint256).max
        });
        nativeHook.addLiquidity{value: 1e18}(params);
        uint256 balanceBAfter = tokenB.balanceOf(user);
        assertEq(balanceBBefore - balanceBAfter, 1e18);
        uint256 liquidity = nativeHook.balanceOf(user);
        console.log(
            "addLiquidity user.balance:%s,liquidity:%s,this.liquidity:%s",
            user.balance,
            liquidity,
            nativeHook.balanceOf(address(this))
        );
        (uint256 _reserves0, uint256 _reserves1) = nativeHook.getReserves();
        assertEq(_reserves0, _reserves1);
        nativeHook.removeLiquidity(liquidity / 2);
        uint256 liquidityHelf = nativeHook.balanceOf(user);
        assertEq(liquidityHelf, liquidity - liquidity / 2);
        vm.stopPrank();
    }

    function test_hook_swap() public {
        vm.startPrank(user);
        tokenB.approve(address(nativeHook), 1e18);
        LiquidityParams memory params = LiquidityParams({
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            recipient: user,
            deadline: type(uint256).max
        });
        nativeHook.addLiquidity{value: 1e18}(params);
        (uint256 _reserves0, uint256 _reserves1) = nativeHook.getReserves();
        assertEq(_reserves0, _reserves1);
        console.log("reserves0:%s,reserves1:%s", _reserves0, _reserves1);
        uint256 amountIn = 100000;
        uint256 amountOut = nativeHook.getAmountOut(address(0), amountIn);
        console.log("amountIn:%s,amountOut:%s", amountIn, amountOut);
        // swap
        address[] memory _path = new address[](2);
        _path[0] = address(0);
        _path[1] = address(tokenB);
        uint256 balance0 = manager.balanceOf(address(nativeHook), 0);
        uint256 balance1 = manager.balanceOf(address(nativeHook), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        console.log("before swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            path: _path,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        swapRouter.exactInput{value: amountIn}(swapParams);
        console.log("swapRouter.balance:%s", manager.balanceOf(address(swapRouter), 0));
        console.log("after swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        (_reserves0, _reserves1) = nativeHook.getReserves();
        console.log("reserves0:%s,reserves1:%s", _reserves0, _reserves1);
        uint256 liquidity = nativeHook.balanceOf(user);
        nativeHook.removeLiquidity(liquidity);
        (_reserves0, _reserves1) = nativeHook.getReserves();
        console.log("reserves0:%s,reserves1:%s", _reserves0, _reserves1);
        console.log("after removeLiquidity user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        vm.stopPrank();
    }

    function test_hook_swapWithFee() public {
        vm.startPrank(user);
        //factory.setFeeTo(address(user));
        tokenB.approve(address(nativeHook), 1e18);
        LiquidityParams memory params = LiquidityParams({
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            recipient: user,
            deadline: type(uint256).max
        });
        nativeHook.addLiquidity{value: 1e18}(params);
        (uint256 _reserves0, uint256 _reserves1) = nativeHook.getReserves();
        assertEq(_reserves0, _reserves1);
        console.log("reserves0:%s,reserves1:%s", _reserves0, _reserves1);
        uint256 amountIn = 100000;
        uint256 amountOut = nativeHook.getAmountOut(address(0), amountIn);
        console.log("swapWithFee.amountIn:%s,amountOut:%s,checkFee:%s", amountIn, amountOut, nativeHook.checkFeeOn());
        // swap
        address[] memory _path = new address[](2);
        _path[0] = address(0);
        _path[1] = address(tokenB);
        uint256 balance0 = manager.balanceOf(address(nativeHook), 0);
        uint256 balance1 = manager.balanceOf(address(nativeHook), uint160(address(tokenB)));
        console.log("hook.balance0:%s,hook.balance1:%s", balance0, balance1);
        console.log("before swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
            path: _path,
            to: user,
            amountIn: amountIn,
            amountOut: 0,
            amountOutMin: 0,
            deadline: type(uint256).max
        });
        swapRouter.exactInput{value: amountIn}(swapParams);
        console.log("after swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        (_reserves0, _reserves1) = nativeHook.getReserves();
        console.log("reserves0:%s,reserves1:%s", _reserves0, _reserves1);

        console.log("before swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        swapRouter.exactInput{value: amountIn}(swapParams);
        console.log("after swap user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        (_reserves0, _reserves1) = nativeHook.getReserves();
        console.log("reserves0:%s,reserves1:%s", _reserves0, _reserves1);
        uint256 liquidity = nativeHook.balanceOf(user);
        nativeHook.removeLiquidity(liquidity);
        (_reserves0, _reserves1) = nativeHook.getReserves();
        console.log("reserves0:%s,reserves1:%s", _reserves0, _reserves1);
        console.log("after removeLiquidity user.balance:%s,tokenB:%s", user.balance, tokenB.balanceOf(user));
        vm.stopPrank();
    }

    function test_hook_borrow() public {
        vm.startPrank(user);
        tokenB.approve(address(nativeHook), 1e18);
        LiquidityParams memory lParams = LiquidityParams({
            amount0: 1e18,
            amount1: 1e18,
            tickLower: 50000,
            tickUpper: 50000,
            recipient: user,
            deadline: type(uint256).max
        });
        nativeHook.addLiquidity{value: 1e18}(lParams);
        (uint256 _reserves0, uint256 _reserves1) = nativeHook.getReserves();
        assertEq(_reserves0, _reserves1);
        uint256 rate = nativeHook.getBorrowRate(Currency.wrap(address(0)));
        assertEq(rate, 50000);
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.01e18;
        MarginParams memory params = MarginParams({
            marginToken: address(0),
            borrowToken: address(tokenB),
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
            address(nativeHook).balance,
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
        rate = nativeHook.getBorrowRate(Currency.wrap(address(tokenB)));
        uint256 rateLast = nativeHook.getBorrowRateCumulativeLast(address(tokenB));
        console.log("rate:%s,rateLast:%s", rate, rateLast);
        vm.warp(3600 * 10);
        uint256 timeElapsed = (3600 * 10 - 1) * 10 ** 3;
        uint256 rateLastX = (ONE_BILLION + rate * timeElapsed / YEAR_SECONDS) * rateLast / ONE_BILLION;
        console.log("timeElapsed:%s,rateLastX:%s", timeElapsed, rateLastX);
        uint256 borrowAmountLast = borrowAmount;
        payValue = 0.02e18;
        params = MarginParams({
            marginToken: address(0),
            borrowToken: address(tokenB),
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
            address(nativeHook).balance,
            address(marginPositionManager).balance
        );
        console.log("positionId:%s,borrowAmount:%s", positionId, borrowAmount);
        position = marginPositionManager.getPosition(positionId);
        uint256 borrowAmountAll = borrowAmount + borrowAmountLast * rateLastX / rateLast;
        assertEq(position.borrowAmount / 100, borrowAmountAll / 100);
        console.log("positionId:%s,position.borrowAmount:%s,all:%s", positionId, position.borrowAmount, borrowAmountAll);

        vm.warp(3600 * 20);
        rate = nativeHook.getBorrowRate(Currency.wrap(address(tokenB)));
        timeElapsed = (3600 * 10) * 10 ** 3;
        rateLast = rateLastX;
        rateLastX = (ONE_BILLION + rate * timeElapsed / YEAR_SECONDS) * rateLast / ONE_BILLION;
        console.log("timeElapsed:%s,rateLast:%s,rateLastX:%s", timeElapsed, rateLast, rateLastX);

        payValue = 0.02e18;
        params = MarginParams({
            marginToken: address(0),
            borrowToken: address(tokenB),
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
            address(nativeHook).balance,
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
        test_hook_borrow();
        vm.startPrank(user);
        uint256 positionId = marginPositionManager.getPositionId(address(nativeHook), address(tokenB));
        assertGt(positionId, 0);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        uint256 userBalance = user.balance;
        console.log("before repay positionId:%s,position.borrowAmount:%s", positionId, position.borrowAmount);
        console.log("before repay balance:%s tokenB.balance:%s", user.balance, tokenB.balanceOf(user));
        uint256 repay = 0.01e18;
        tokenB.approve(address(nativeHook), repay);
        marginPositionManager.repay(positionId, repay, UINT256_MAX);
        MarginPosition memory newPosition = marginPositionManager.getPosition(positionId);
        console.log("after repay balance:%s tokenB.balance:%s", user.balance, tokenB.balanceOf(user));
        console.log("after repay positionId:%s,position.borrowAmount:%s", positionId, newPosition.borrowAmount);
        assertEq(position.borrowAmount - newPosition.borrowAmount, repay);
        assertEq(position.marginTotal - newPosition.marginTotal, user.balance - userBalance);
        vm.stopPrank();
    }

    function test_hook_liquidate() public {
        test_hook_borrow();
        vm.startPrank(user);
        uint256 positionId = marginPositionManager.getPositionId(address(nativeHook), address(tokenB));
        assertGt(positionId, 0);
        MarginPosition memory position = marginPositionManager.getPosition(positionId);
        (bool liquided, uint256 releaseAmount) = marginPositionManager.checkLiquidate(positionId);
        uint256 amountIn = 0.1 ether;
        address[] memory _path = new address[](2);
        _path[0] = address(0);
        _path[1] = address(tokenB);
        while (!liquided) {
            MarginRouter.SwapParams memory swapParams = MarginRouter.SwapParams({
                path: _path,
                to: user,
                amountIn: amountIn,
                amountOut: 0,
                amountOutMin: 0,
                deadline: type(uint256).max
            });
            swapRouter.exactInput{value: amountIn}(swapParams);
            (liquided, releaseAmount) = marginPositionManager.checkLiquidate(positionId);
            console.log("releaseAmount:%s", releaseAmount);
        }
        console.log(
            "before liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(nativeHook).balance,
            address(marginPositionManager).balance
        );
        marginPositionManager.liquidate(positionId);
        position = marginPositionManager.getPosition(positionId);
        console.log(
            "after liquidate nativeHook.balance:%s,marginPositionManager.balance:%s",
            address(nativeHook).balance,
            address(marginPositionManager).balance
        );
        vm.stopPrank();
    }
}
