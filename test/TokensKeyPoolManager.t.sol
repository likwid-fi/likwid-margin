// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Local
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {MirrorTokenManager} from "../src/MirrorTokenManager.sol";
import {MarginPositionManager} from "../src/MarginPositionManager.sol";
import {MarginLiquidity} from "../src/MarginLiquidity.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {PoolStatus} from "../src/types/PoolStatus.sol";
import {PoolStatusLibrary} from "../src/types/PoolStatusLibrary.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {PerLibrary} from "../src/libraries/PerLibrary.sol";
import {CurrencyPoolLibrary} from "../src/libraries/CurrencyPoolLibrary.sol";
import {AddLiquidityParams, RemoveLiquidityParams} from "../src/types/LiquidityParams.sol";
import {LiquidityLevel} from "../src/libraries/LiquidityLevel.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition, MarginPositionVo} from "../src/types/MarginPosition.sol";
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
import {EIP20NonStandardThrowHarness} from "./mocks/EIP20NonStandardThrowHarness.sol";

import {DeployHelper} from "./utils/DeployHelper.sol";

contract TokensKeyPoolManagerTest is DeployHelper {
    using CurrencyPoolLibrary for Currency;
    using PoolStatusLibrary for *;
    using LiquidityLevel for uint8;

    MockERC20 token0;
    MockERC20 token1;

    function setUp() public {
        deployHookAndRouter();
        initTokensKey();
        initUSDTKey();
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function testTokensDepositAndWithdraw() public {
        address user = vm.addr(1);
        token0.transfer(user, 1 ether);
        PoolId tokensId = tokensKey.toId();
        uint256 id = tokensKey.currency0.toTokenId(tokensId);
        vm.startPrank(user);
        uint256 lb = lendingPoolManager.balanceOf(user, id);
        assertEq(lb, 0);
        token0.approve(address(lendingPoolManager), 0.1 ether);
        lendingPoolManager.deposit(user, tokensId, tokensKey.currency0, 0.1 ether);
        uint256 ethAmount = manager.balanceOf(address(lendingPoolManager), tokensKey.currency0.toId());
        lb = lendingPoolManager.balanceOf(user, id);
        console.log("lending.balance:%s,ethAmount:%s", lb, ethAmount);
        lendingPoolManager.withdraw(user, tokensId, tokensKey.currency0, 0.01 ether);
        ethAmount = manager.balanceOf(address(lendingPoolManager), tokensKey.currency0.toId());
        lb = lendingPoolManager.balanceOf(user, id);
        assertEq(ethAmount, lb, "DepositAndWithdraw");
        vm.stopPrank();
    }

    function testTokensUpdateInterests() public {
        testTokensDepositAndWithdraw();
        address user = vm.addr(1);
        PoolId tokensId = tokensKey.toId();
        uint256 token1Id = tokensKey.currency1.toTokenId(tokensId);
        uint256 token1Amount = manager.balanceOf(address(lendingPoolManager), tokensKey.currency1.toId());
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.001 ether;
        address user0 = address(this);
        MarginParams memory params = MarginParams({
            poolId: tokensKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user0,
            deadline: block.timestamp + 1000
        });
        (positionId, borrowAmount) = marginPositionManager.margin(params);
        skip(3600 * 10);
        borrowAmount = marginPositionManager.getPosition(positionId).borrowAmount;
        console.log("borrowAmount:%s", borrowAmount);
        marginPositionManager.close(positionId, PerLibrary.ONE_MILLION, 0, block.timestamp + 1001);
        uint256 lb = lendingPoolManager.balanceOf(user, token1Id);
        uint256 mirror1Balance = mirrorTokenManager.balanceOf(address(lendingPoolManager), token1Id);
        token1Amount = manager.balanceOf(address(lendingPoolManager), tokensKey.currency1.toId());
        console.log("lending.balance:%s,token1Amount:%s,mirrorBalance:%s", lb, token1Amount, mirror1Balance);
    }

    function testUSDTDepositAndWithdraw() public {
        address user = vm.addr(1);
        (bool success,) = user.call{value: 1 ether}("");
        require(success, "TRANSFER_FAILED");
        tokenUSDT.transfer(user, 1 ether);
        PoolId tokensId = usdtKey.toId();
        uint256 id = usdtKey.currency0.toTokenId(tokensId);
        vm.startPrank(user);
        uint256 lb = lendingPoolManager.balanceOf(user, id);
        assertEq(lb, 0);
        lendingPoolManager.deposit{value: 0.1 ether}(user, tokensId, usdtKey.currency0, 0.1 ether);
        uint256 ethAmount = manager.balanceOf(address(lendingPoolManager), usdtKey.currency0.toId());
        lb = lendingPoolManager.balanceOf(user, id);
        console.log("lending.balance:%s,ethAmount:%s", lb, ethAmount);
        lendingPoolManager.withdraw(user, tokensId, usdtKey.currency0, 0.01 ether);
        ethAmount = manager.balanceOf(address(lendingPoolManager), usdtKey.currency0.toId());
        lb = lendingPoolManager.balanceOf(user, id);
        assertEq(ethAmount, lb, "DepositAndWithdraw");
        vm.stopPrank();
    }

    function testUSDTUpdateInterests() public {
        testUSDTDepositAndWithdraw();
        address user = vm.addr(1);
        PoolId tokensId = usdtKey.toId();
        uint256 token1Id = usdtKey.currency1.toTokenId(tokensId);
        uint256 token1Amount = manager.balanceOf(address(lendingPoolManager), usdtKey.currency1.toId());
        uint256 positionId;
        uint256 borrowAmount;
        uint256 payValue = 0.001 ether;
        address user0 = address(this);
        MarginParams memory params = MarginParams({
            poolId: usdtKey.toId(),
            marginForOne: false,
            leverage: 3,
            marginAmount: payValue,
            borrowAmount: 0,
            borrowMaxAmount: 0,
            recipient: user0,
            deadline: block.timestamp + 1002
        });
        (positionId, borrowAmount) = marginPositionManager.margin{value: payValue}(params);
        skip(3600 * 10);
        borrowAmount = marginPositionManager.getPosition(positionId).borrowAmount;
        console.log("borrowAmount:%s", borrowAmount);
        marginPositionManager.close(positionId, PerLibrary.ONE_MILLION, 0, block.timestamp + 1003);
        uint256 lb = lendingPoolManager.balanceOf(user, token1Id);
        uint256 mirror1Balance = mirrorTokenManager.balanceOf(address(lendingPoolManager), token1Id);
        token1Amount = manager.balanceOf(address(lendingPoolManager), usdtKey.currency1.toId());
        console.log("lending.balance:%s,token1Amount:%s,mirrorBalance:%s", lb, token1Amount, mirror1Balance);
    }

    function testUSDTTokensLiquidity() public {
        AddLiquidityParams memory params = AddLiquidityParams({
            poolId: usdtKey.toId(),
            level: 1,
            amount0: 1 ether,
            amount1: 100 ether,
            to: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: 1 ether}(params);
        params = AddLiquidityParams({
            poolId: usdtKey.toId(),
            level: 2,
            amount0: 1 ether,
            amount1: 100 ether,
            to: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: 1 ether}(params);
        params = AddLiquidityParams({
            poolId: usdtKey.toId(),
            level: 3,
            amount0: 1 ether,
            amount1: 100 ether,
            to: address(this),
            deadline: type(uint256).max
        });
        pairPoolManager.addLiquidity{value: 1 ether}(params);
        (uint256[4] memory liquidities) = marginLiquidity.getPoolLiquidities(usdtKey.toId(), address(this));
        assertEq(liquidities[0], liquidities[1], "level1==level2");
        assertEq(liquidities[0], liquidities[2], "level1==level3");
        assertEq(liquidities[0], liquidities[3], "level1==level4");
        testUSDTUpdateInterests();
        testTokensUpdateInterests();
        liquidities = marginLiquidity.getPoolLiquidities(usdtKey.toId(), address(this));
        assertEq(liquidities[0], liquidities[1], "level1==level2");
        assertLt(liquidities[0], liquidities[2], "level1<level3");
        assertLt(liquidities[0], liquidities[3], "level1<level4");
        (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1) =
            marginLiquidity.getPoolSupplies(address(pairPoolManager), usdtKey.toId());
        console.log("totalSupply:%s,retainSupply0:%s,retainSupply1:%s", totalSupply, retainSupply0, retainSupply1);
        assertEq(
            liquidities[0] + liquidities[1] + liquidities[2] + liquidities[3] + 1,
            totalSupply,
            "liquidities == totalSupply"
        );
        assertEq(liquidities[0] + liquidities[2], retainSupply0, "level1& level3 liquidities == retainSupply0");
        assertEq(liquidities[0] + liquidities[1], retainSupply1, "level1& level2 liquidities == retainSupply1");
        for (uint8 i = 0; i < 4; i++) {
            RemoveLiquidityParams memory removeParams = RemoveLiquidityParams({
                poolId: usdtKey.toId(),
                level: i + 1,
                liquidity: liquidities[i],
                deadline: type(uint256).max
            });
            vm.roll(100);
            skip(3600 * 2);
            pairPoolManager.removeLiquidity(removeParams);
        }
        (totalSupply, retainSupply0, retainSupply1) =
            marginLiquidity.getPoolSupplies(address(pairPoolManager), usdtKey.toId());
        console.log("totalSupply:%s,retainSupply0:%s,retainSupply1:%s", totalSupply, retainSupply0, retainSupply1);
    }
}
