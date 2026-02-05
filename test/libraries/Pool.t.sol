// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pool} from "../../src/libraries/Pool.sol";
import {BalanceDelta, toBalanceDelta} from "../../src/types/BalanceDelta.sol";
import {toReserves} from "../../src/types/Reserves.sol";
import {PairPosition} from "../../src/libraries/PairPosition.sol";
import {Math} from "../../src/libraries/Math.sol";

contract PoolTest is Test {
    using Pool for Pool.State;
    using PairPosition for mapping(bytes32 => PairPosition.State);

    Pool.State private pool;

    function setUp() public {
        pool.initialize(200, 3000); // 0.02% lpFee,0.3% marginFee
    }

    function testModifyLiquidityAddInitialLiquidity() public {
        uint256 amount0 = 1e18;
        uint256 amount1 = 4e18;
        bytes32 salt = keccak256("salt");
        address owner = address(this);

        Pool.ModifyLiquidityParams memory params = Pool.ModifyLiquidityParams({
            owner: owner,
            amount0: amount0,
            amount1: amount1,
            liquidityDelta: 0, // Should be calculated from amounts
            salt: salt
        });

        // --- Action ---
        (BalanceDelta delta,) = pool.modifyLiquidity(params);

        // --- Assertions ---

        // 1. Check returned delta (ISSUE: This will fail, current implementation returns 0)
        int128 expectedAmount0 = -int128(int256(amount0));
        int128 expectedAmount1 = -int128(int256(amount1));
        assertEq(int256(delta.amount0()), int256(expectedAmount0), "Delta amount0 should be negative amount added");
        assertEq(int256(delta.amount1()), int256(expectedAmount1), "Delta amount1 should be negative amount added");

        // 2. Check pool state
        uint128 expectedLiquidity = uint128(Math.sqrt(amount0 * amount1));
        assertEq(
            uint256(pool.slot0.totalSupply()),
            uint256(expectedLiquidity) + 1000,
            "Total supply should be sqrt(amount0 * amount1)"
        );

        // 3. Check position state
        PairPosition.State storage position = pool.positions.get(owner, salt);
        assertEq(uint256(position.liquidity), uint256(expectedLiquidity), "Position liquidity should be updated");
    }

    function testModifyLiquidityRemoveLiquidity() public {
        // --- Setup: Add initial liquidity first ---
        uint256 amount0Add = 1e18;
        uint256 amount1Add = 4e18;
        uint128 initialLiquidity = uint128(Math.sqrt(amount0Add * amount1Add));

        pool.slot0 = pool.slot0.setTotalSupply(initialLiquidity);
        pool.pairReserves = toReserves(uint128(amount0Add), uint128(amount1Add));
        pool.realReserves = toReserves(uint128(amount0Add), uint128(amount1Add));

        bytes32 salt = keccak256("salt");
        address owner = address(this);
        PairPosition.update(
            pool.positions.get(owner, salt),
            int128(initialLiquidity),
            toBalanceDelta(-int128(int256(amount0Add)), -int128(int256(amount1Add)))
        );

        // --- Action: Remove half of the liquidity ---
        int128 liquidityToRemove = -int128(initialLiquidity / 2);
        Pool.ModifyLiquidityParams memory params = Pool.ModifyLiquidityParams({
            owner: owner,
            amount0: 0, // Not used for removal
            amount1: 0, // Not used for removal
            liquidityDelta: liquidityToRemove,
            salt: salt
        });

        (BalanceDelta delta,) = pool.modifyLiquidity(params);

        // --- Assertions ---

        // 1. Check returned delta
        uint256 expectedAmount0Out = (amount0Add / 2);
        uint256 expectedAmount1Out = (amount1Add / 2);
        assertEq(uint256(int256(delta.amount0())), expectedAmount0Out, "Delta amount0 should be amount removed");
        assertEq(uint256(int256(delta.amount1())), expectedAmount1Out, "Delta amount1 should be amount removed");

        // 2. Check pool state
        uint128 expectedFinalSupply = initialLiquidity / 2;
        assertEq(uint256(pool.slot0.totalSupply()), uint256(expectedFinalSupply), "Total supply should be reduced");

        // 3. Check position state
        PairPosition.State storage position = pool.positions.get(owner, salt);
        uint128 expectedFinalLiquidity = initialLiquidity - (initialLiquidity / 2);
        assertEq(uint256(position.liquidity), uint256(expectedFinalLiquidity), "Position liquidity should be reduced");
    }

    function testModifyLiquidityAddMoreLiquidity() public {
        // --- Setup: Add initial liquidity first ---
        uint256 amount0Add = 1e18;
        uint256 amount1Add = 4e18;
        bytes32 salt = keccak256("salt");
        address owner = address(this);

        Pool.ModifyLiquidityParams memory params = Pool.ModifyLiquidityParams({
            owner: owner, amount0: amount0Add, amount1: amount1Add, liquidityDelta: 0, salt: salt
        });

        pool.modifyLiquidity(params);
        uint128 liquidityAfterFirst = pool.slot0.totalSupply();

        // Add more liquidity
        uint256 amount0Second = 0.5e18;
        uint256 amount1Second = 2e18;
        params = Pool.ModifyLiquidityParams({
            owner: owner, amount0: amount0Second, amount1: amount1Second, liquidityDelta: 0, salt: salt
        });

        (BalanceDelta delta2,) = pool.modifyLiquidity(params);

        // --- Assertions ---
        assertTrue(pool.slot0.totalSupply() > liquidityAfterFirst, "Total supply should increase");
        assertLt(int256(delta2.amount0()), 0, "Delta amount0 should be negative");
        assertLt(int256(delta2.amount1()), 0, "Delta amount1 should be negative");
    }

    function testModifyLiquidityRemoveAllLiquidity() public {
        // --- Setup: Add initial liquidity first ---
        uint256 amount0Add = 1e18;
        uint256 amount1Add = 4e18;
        uint128 initialLiquidity = uint128(Math.sqrt(amount0Add * amount1Add));

        pool.slot0 = pool.slot0.setTotalSupply(initialLiquidity);
        pool.pairReserves = toReserves(uint128(amount0Add), uint128(amount1Add));
        pool.realReserves = toReserves(uint128(amount0Add), uint128(amount1Add));

        bytes32 salt = keccak256("salt");
        address owner = address(this);
        PairPosition.update(
            pool.positions.get(owner, salt),
            int128(initialLiquidity),
            toBalanceDelta(-int128(int256(amount0Add)), -int128(int256(amount1Add)))
        );

        // --- Action: Remove all liquidity ---
        int128 liquidityToRemove = -int128(initialLiquidity);
        Pool.ModifyLiquidityParams memory params = Pool.ModifyLiquidityParams({
            owner: owner, amount0: 0, amount1: 0, liquidityDelta: liquidityToRemove, salt: salt
        });

        (BalanceDelta delta,) = pool.modifyLiquidity(params);

        // --- Assertions ---
        assertEq(pool.slot0.totalSupply(), 0, "Total supply should be 0");
        assertGt(int256(delta.amount0()), 0, "Should receive amount0 back");
        assertGt(int256(delta.amount1()), 0, "Should receive amount1 back");
    }

    function testSwap() public {
        // --- Setup: Add initial liquidity ---
        uint256 amount0Add = 10e18;
        uint256 amount1Add = 10e18;
        bytes32 salt = keccak256("salt");
        address owner = address(this);

        Pool.ModifyLiquidityParams memory liquidityParams = Pool.ModifyLiquidityParams({
            owner: owner, amount0: amount0Add, amount1: amount1Add, liquidityDelta: 0, salt: salt
        });

        pool.modifyLiquidity(liquidityParams);

        // --- Action: Swap token0 for token1 ---
        int256 amountIn = -1e18; // Exact input
        Pool.SwapParams memory swapParams = Pool.SwapParams({
            sender: address(this), zeroForOne: true, amountSpecified: amountIn, useMirror: false, salt: bytes32(0)
        });

        (BalanceDelta swapDelta,, uint24 swapFee, uint256 feeAmount) = pool.swap(swapParams, 0);

        // --- Assertions ---
        assertLt(int256(swapDelta.amount0()), 0, "Amount0 should be negative (sent)");
        assertGt(int256(swapDelta.amount1()), 0, "Amount1 should be positive (received)");
        assertGt(swapFee, 0, "Swap fee should be set");
        assertGt(feeAmount, 0, "Fee amount should be positive");
    }

    function testSwapExactOutput() public {
        // --- Setup: Add initial liquidity ---
        uint256 amount0Add = 10e18;
        uint256 amount1Add = 10e18;
        bytes32 salt = keccak256("salt");
        address owner = address(this);

        Pool.ModifyLiquidityParams memory liquidityParams = Pool.ModifyLiquidityParams({
            owner: owner, amount0: amount0Add, amount1: amount1Add, liquidityDelta: 0, salt: salt
        });

        pool.modifyLiquidity(liquidityParams);

        // --- Action: Swap for exact output ---
        int256 amountOut = 0.5e18; // Exact output
        Pool.SwapParams memory swapParams = Pool.SwapParams({
            sender: address(this), zeroForOne: true, amountSpecified: amountOut, useMirror: false, salt: bytes32(0)
        });

        (BalanceDelta swapDelta,,,) = pool.swap(swapParams, 0);

        // --- Assertions ---
        assertLt(int256(swapDelta.amount0()), 0, "Amount0 should be negative (sent)");
        assertEq(uint256(int256(swapDelta.amount1())), uint256(amountOut), "Amount1 should equal exact output");
    }

    function testLend() public {
        // --- Setup: Add initial liquidity ---
        uint256 amount0Add = 10e18;
        uint256 amount1Add = 10e18;
        bytes32 salt = keccak256("salt");
        address owner = address(this);

        Pool.ModifyLiquidityParams memory liquidityParams = Pool.ModifyLiquidityParams({
            owner: owner, amount0: amount0Add, amount1: amount1Add, liquidityDelta: 0, salt: salt
        });

        pool.modifyLiquidity(liquidityParams);

        // --- Action: Lend token0 ---
        int128 lendAmount = -1e18;
        bytes32 lendSalt = keccak256("lend_salt");
        Pool.LendParams memory lendParams =
            Pool.LendParams({sender: address(this), lendForOne: false, lendAmount: lendAmount, salt: lendSalt});

        (BalanceDelta lendDelta, uint256 depositCumulativeLast) = pool.lend(lendParams);

        // --- Assertions ---
        assertLt(int256(lendDelta.amount0()), 0, "Amount0 should be negative (lent)");
        assertEq(int256(lendDelta.amount1()), 0, "Amount1 should be 0");
        assertGt(depositCumulativeLast, 0, "Deposit cumulative last should be set");
    }

    function testDonate() public {
        // --- Setup: Add initial liquidity ---
        uint256 amount0Add = 10e18;
        uint256 amount1Add = 10e18;
        bytes32 salt = keccak256("salt");
        address owner = address(this);

        Pool.ModifyLiquidityParams memory liquidityParams = Pool.ModifyLiquidityParams({
            owner: owner, amount0: amount0Add, amount1: amount1Add, liquidityDelta: 0, salt: salt
        });

        pool.modifyLiquidity(liquidityParams);

        // --- Action: Donate to insurance fund ---
        uint256 donate0 = 1e18;
        uint256 donate1 = 1e18;
        BalanceDelta delta = pool.donate(donate0, donate1);

        // --- Assertions ---
        assertLt(int256(delta.amount0()), 0, "Amount0 should be negative (donated)");
        assertLt(int256(delta.amount1()), 0, "Amount1 should be negative (donated)");
    }

    function testDonateZero() public {
        BalanceDelta delta = pool.donate(0, 0);
        assertEq(BalanceDelta.unwrap(delta), 0, "Delta should be zero for zero donation");
    }

    function testSetProtocolFee() public {
        uint24 newFee = 0x141414;
        pool.setProtocolFee(newFee);
        assertEq(pool.slot0.protocolFee(0), newFee, "Protocol fee should be updated");
    }

    function testSetInsuranceFundPercentage() public {
        uint8 newPercentage = 50;
        pool.setInsuranceFundPercentage(newPercentage);
        assertEq(pool.slot0.insuranceFundPercentage(), newPercentage, "Insurance fund percentage should be updated");
    }
}
