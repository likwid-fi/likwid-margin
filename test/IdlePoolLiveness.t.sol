// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LikwidVault} from "../src/LikwidVault.sol";
import {LikwidMarginPosition} from "../src/LikwidMarginPosition.sol";
import {LikwidPairPosition} from "../src/LikwidPairPosition.sol";
import {IPairPositionManager} from "../src/interfaces/IPairPositionManager.sol";
import {IMarginPositionManager} from "../src/interfaces/IMarginPositionManager.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {Currency} from "../src/types/Currency.sol";
import {StateLibrary} from "../src/libraries/StateLibrary.sol";
import {LikwidHelper} from "./utils/LikwidHelper.sol";

/// A pool with a large raw reserve0 (a meme token with 1e30 raw units) used to freeze after a few idle days:
/// PriceMath.transferReserves overflowed its unused upper bound and every entry point reverted SafeCastOverflow.
contract IdlePoolLivenessTest is Test {
    using PoolIdLibrary for PoolKey;

    LikwidVault vault;
    LikwidPairPosition pairPositionManager;
    LikwidMarginPosition marginPositionManager;
    LikwidHelper helper;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId id;
    uint256 lpTokenId;
    uint128 lpLiquidity;
    uint256 positionId;

    function setUp() public {
        vault = new LikwidVault(address(this));
        pairPositionManager = new LikwidPairPosition(address(this), vault);
        marginPositionManager = new LikwidMarginPosition(address(this), vault);
        helper = new LikwidHelper(address(this), vault);
        vault.setMarginController(address(marginPositionManager));
        vault.setMarginState(vault.marginState().setStageDuration(0));

        MockERC20 tokenA = new MockERC20("TokenA", "TKNA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TKNB", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        token0.approve(address(pairPositionManager), type(uint256).max);
        token1.approve(address(pairPositionManager), type(uint256).max);
        token0.approve(address(marginPositionManager), type(uint256).max);
        token1.approve(address(marginPositionManager), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            marginFee: 3000
        });
        vault.initialize(key);
        id = key.toId();

        token0.mint(address(this), 1e30);
        token1.mint(address(this), 100e18);
        (lpTokenId, lpLiquidity) =
            pairPositionManager.addLiquidity(key, address(this), 1e30, 100e18, 0, 0, block.timestamp);

        token0.mint(address(this), 1e27);
        (positionId,,) = marginPositionManager.addMargin(
            key,
            IMarginPositionManager.CreateParams({
                marginForOne: false,
                leverage: 2,
                marginAmount: 1e27,
                borrowAmountMax: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    function _swap(uint256 amountIn) internal {
        token0.mint(address(this), amountIn);
        pairPositionManager.exactInput(
            IPairPositionManager.SwapInputParams({
                poolId: id,
                zeroForOne: true,
                to: address(this),
                amountIn: amountIn,
                amountOutMin: 0,
                deadline: block.timestamp
            })
        );
    }

    function _assertEverythingWorks() internal {
        helper.getPoolStateInfo(id);
        helper.checkMarginPositionLiquidate(positionId);
        _swap(1e18);
        pairPositionManager.removeLiquidity(lpTokenId, lpLiquidity / 10, 0, 0, block.timestamp);
        token1.mint(address(this), 1e18);
        marginPositionManager.repay(positionId, 1e15, block.timestamp);
        marginPositionManager.close(positionId, 1_000_000, 0, block.timestamp);
        (uint128 t0, uint128 t1) = StateLibrary.getTruncatedReserves(vault, id).reserves();
        assertGt(t0, 0);
        assertGt(t1, 0);
    }

    /// Past the old freeze point (336,452 s for this pool) everything still works.
    function testIdle_PastOldFreezePoint() public {
        skip(336_452);
        _assertEverythingWorks();
    }

    /// Idle for a year: still works, and the truncated reserves simply follow the pair.
    function testIdle_OneYear() public {
        skip(365 days);
        _swap(1e9);
        (uint128 p0,) = StateLibrary.getPairReserves(vault, id).reserves();
        (uint128 t0, uint128 t1) = StateLibrary.getTruncatedReserves(vault, id).reserves();
        // the first update after the idle year follows the pair; the tiny swap after it moves the pair slightly
        assertApproxEqRel(t0, p0, 1e12);
        assertGt(t1, 0);
        skip(1);
        _assertEverythingWorks();
    }
}
