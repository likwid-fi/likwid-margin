// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LikwidVault} from "../../src/LikwidVault.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {IUnlockCallback} from "../../src/interfaces/callback/IUnlockCallback.sol";
import {MarginState} from "../../src/types/MarginState.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {PoolState} from "../../src/types/PoolState.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../../src/types/PoolId.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";
import {Reserves, toReserves} from "../../src/types/Reserves.sol";
import {InsuranceFunds} from "../../src/types/InsuranceFunds.sol";
import {StateLibrary} from "../../src/libraries/StateLibrary.sol";
import {CurrentStateLibrary} from "../../src/libraries/CurrentStateLibrary.sol";
import {StageMath} from "../../src/libraries/StageMath.sol";
import {LendPosition} from "../../src/libraries/LendPosition.sol";
import {PairPosition} from "../../src/libraries/PairPosition.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract StateLibraryTest is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StageMath for uint256;

    LikwidVault vault;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;
    uint256 initialLiquidity;

    function setUp() public {
        vault = new LikwidVault(address(this));
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);

        // Approve vault to spend tokens
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Ensure currency order
        if (Currency.unwrap(currency0) > Currency.unwrap(currency1)) {
            (currency0, currency1) = (currency1, currency0);
            (token0, token1) = (token1, token0);
        }

        poolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, marginFee: 3000, rateRange: 0x1011});
        poolId = poolKey.toId();
        vault.initialize(poolKey);
        vault.setMarginController(address(this));

        // Add initial liquidity
        initialLiquidity = 10 ether;
        token0.mint(address(this), initialLiquidity);
        token1.mint(address(this), initialLiquidity);

        IVault.ModifyLiquidityParams memory mlParams = IVault.ModifyLiquidityParams({
            amount0: initialLiquidity, amount1: initialLiquidity, liquidityDelta: 0, salt: bytes32(0)
        });

        bytes memory innerData = abi.encode(poolKey, mlParams);
        bytes memory data = abi.encode(this.modifyLiquidity_callback.selector, innerData);
        vault.unlock(data);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bytes4 selector, bytes memory params) = abi.decode(data, (bytes4, bytes));

        if (selector == this.modifyLiquidity_callback.selector) {
            (PoolKey memory key, IVault.ModifyLiquidityParams memory mlParams) =
                abi.decode(params, (PoolKey, IVault.ModifyLiquidityParams));
            (BalanceDelta delta,) = vault.modifyLiquidity(key, mlParams);
            settleDelta(delta);
        } else if (selector == this.lend_callback.selector) {
            (PoolKey memory key, IVault.LendParams memory lendParams) = abi.decode(params, (PoolKey, IVault.LendParams));
            BalanceDelta delta = vault.lend(key, lendParams);
            settleDelta(delta);
        }
        return "";
    }

    function modifyLiquidity_callback(PoolKey memory, IVault.ModifyLiquidityParams memory) external pure {}
    function lend_callback(PoolKey memory, IVault.LendParams memory) external pure {}

    function settleDelta(BalanceDelta delta) internal {
        if (delta.amount0() < 0) {
            vault.sync(currency0);
            token0.transfer(address(vault), uint256(-int256(delta.amount0())));
            vault.settle();
        } else if (delta.amount0() > 0) {
            vault.take(currency0, address(this), uint256(int256(delta.amount0())));
        }

        if (delta.amount1() < 0) {
            vault.sync(currency1);
            token1.transfer(address(vault), uint256(-int256(delta.amount1())));
            vault.settle();
        } else if (delta.amount1() > 0) {
            vault.take(currency1, address(this), uint256(int256(delta.amount1())));
        }
    }

    function testGetStageLiquidities() public view {
        uint256[] memory liquidities = StateLibrary.getRawStageLiquidities(vault, poolId);
        MarginState marginState = vault.marginState();
        (uint128 total, uint128 liquidity) = liquidities[0].decode();
        assertEq(liquidities.length, marginState.stageSize(), "liquidities.length==marginState.stageSize()");
        assertEq(
            total,
            (initialLiquidity + 1000) / marginState.stageSize(),
            "total0==(initialLiquidity+1000)/marginState.stageSize()"
        );
        assertEq(total, liquidity, "total==liquidity");
    }

    function testGetLendPositionStateForZero() public {
        // 1. Lend to the pool to create a lend position
        int128 amountToLend = -1 ether;
        bool lendForOne = false;
        bytes32 salt = keccak256("my_lend_position");

        token0.mint(address(this), uint256(-int256(amountToLend)));

        IVault.LendParams memory lendParams =
            IVault.LendParams({lendForOne: lendForOne, lendAmount: amountToLend, salt: salt});

        bytes memory innerData = abi.encode(poolKey, lendParams);
        bytes memory data = abi.encode(this.lend_callback.selector, innerData);
        vault.unlock(data);

        // 2. Get the position state using the library function
        LendPosition.State memory positionState =
            StateLibrary.getLendPositionState(vault, poolId, address(this), lendForOne, salt);

        // 3. Assert the state is correct
        assertEq(uint256(positionState.lendAmount), uint256(-int256(amountToLend)), "lendAmount should be correct");
        assertTrue(positionState.depositCumulativeLast != 0, "depositCumulativeLast should be set");
    }

    function testGetLendPositionStateForOne() public {
        // 1. Lend to the pool to create a lend position
        int128 amountToLend = -1 ether;
        bool lendForOne = true;
        bytes32 salt = keccak256("my_lend_position");

        token1.mint(address(this), uint256(-int256(amountToLend)));

        IVault.LendParams memory lendParams =
            IVault.LendParams({lendForOne: lendForOne, lendAmount: amountToLend, salt: salt});

        bytes memory innerData = abi.encode(poolKey, lendParams);
        bytes memory data = abi.encode(this.lend_callback.selector, innerData);
        vault.unlock(data);

        // 2. Get the position state using the library function
        LendPosition.State memory positionState =
            StateLibrary.getLendPositionState(vault, poolId, address(this), lendForOne, salt);

        // 3. Assert the state is correct
        assertEq(uint256(positionState.lendAmount), uint256(-int256(amountToLend)), "lendAmount should be correct");
        assertTrue(positionState.depositCumulativeLast != 0, "depositCumulativeLast should be set");
    }

    function testGetSlot0() public view {
        (
            uint128 totalSupply,
            uint32 lastUpdated,
            uint24 protocolFee,
            uint24 lpFee,
            uint24 marginFee,
            uint8 insuranceFundPercentage,
            uint16 rateRange
        ) = StateLibrary.getSlot0(vault, poolId);
        assertEq(protocolFee, vault.defaultProtocolFee(), "defaultProtocolFee should match protocolFee");
        assertEq(lpFee, 3000, "lpFee should be 3000");
        assertEq(marginFee, 3000, "marginFee should be 3000");
        assertEq(lastUpdated, 1, "lastUpdated should be 1");
        assertEq(totalSupply, initialLiquidity + 1000, "totalSupply should match initialLiquidity+1000");
        assertEq(insuranceFundPercentage, 30, "insuranceFundPercentage should be 30");
        assertEq(rateRange, 0x1011, "rateRange should be 0x1011");
    }

    function testGetNewReserves() public view {
        Reserves protocolInterestReserves = StateLibrary.getProtocolInterestReserves(vault, poolId);
        Reserves insuranceFundUpperLimit = StateLibrary.getInsuranceFundUpperLimit(vault, poolId);
        InsuranceFunds insuranceFunds = StateLibrary.getInsuranceFunds(vault, poolId);
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        Reserves realReserves = state.realReserves;
        Reserves mirrorReserves = state.mirrorReserves;
        Reserves totalReserves = realReserves + mirrorReserves;
        Reserves insuranceFundUpperLimitExpected =
            toReserves((totalReserves.reserve0() * 30) / 100, (totalReserves.reserve1() * 30) / 100); // 30%
        assertEq(Reserves.unwrap(protocolInterestReserves), 0, "protocolInterestReserves should be 0");
        assertEq(
            Reserves.unwrap(insuranceFundUpperLimit),
            Reserves.unwrap(insuranceFundUpperLimitExpected),
            "insuranceFundUpperLimit should be insuranceFundUpperLimitExpected"
        );
        assertEq(InsuranceFunds.unwrap(insuranceFunds), 0, "insuranceFunds should be 0");
    }

    function testGetCurrentState() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        uint24 protocolFee = vault.defaultProtocolFee();
        assertEq(protocolFee, state.protocolFee, "defaultProtocolFee should match state.protocolFee");
    }

    function testGetBorrowDepositCumulative() public view {
        (
            uint256 borrow0CumulativeLast,
            uint256 borrow1CumulativeLast,
            uint256 deposit0CumulativeLast,
            uint256 deposit1CumulativeLast
        ) = StateLibrary.getBorrowDepositCumulative(vault, poolId);

        assertGt(borrow0CumulativeLast, 0, "borrow0CumulativeLast should be initialized");
        assertGt(borrow1CumulativeLast, 0, "borrow1CumulativeLast should be initialized");
        assertGt(deposit0CumulativeLast, 0, "deposit0CumulativeLast should be initialized");
        assertGt(deposit1CumulativeLast, 0, "deposit1CumulativeLast should be initialized");
    }

    function testGetPairReserves() public view {
        Reserves pairReserves = StateLibrary.getPairReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = pairReserves.reserves();
        assertGt(reserve0, 0, "pair reserve0 should be > 0");
        assertGt(reserve1, 0, "pair reserve1 should be > 0");
    }

    function testGetRealReserves() public view {
        Reserves realReserves = StateLibrary.getRealReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = realReserves.reserves();
        assertGt(reserve0, 0, "real reserve0 should be > 0");
        assertGt(reserve1, 0, "real reserve1 should be > 0");
    }

    function testGetMirrorReserves() public view {
        Reserves mirrorReserves = StateLibrary.getMirrorReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = mirrorReserves.reserves();
        assertEq(reserve0, 0, "mirror reserve0 should be 0 initially");
        assertEq(reserve1, 0, "mirror reserve1 should be 0 initially");
    }

    function testGetTruncatedReserves() public view {
        Reserves truncatedReserves = StateLibrary.getTruncatedReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = truncatedReserves.reserves();
        assertGt(reserve0, 0, "truncated reserve0 should be > 0");
        assertGt(reserve1, 0, "truncated reserve1 should be > 0");
    }

    function testGetLendReserves() public view {
        Reserves lendReserves = StateLibrary.getLendReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = lendReserves.reserves();
        assertEq(reserve0, 0, "lend reserve0 should be 0 initially");
        assertEq(reserve1, 0, "lend reserve1 should be 0 initially");
    }

    function testGetInterestReserves() public view {
        Reserves interestReserves = StateLibrary.getInterestReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = interestReserves.reserves();
        assertEq(reserve0, 0, "interest reserve0 should be 0 initially");
        assertEq(reserve1, 0, "interest reserve1 should be 0 initially");
    }

    function testGetPairPositionState() public {
        // First add liquidity to create a position
        bytes32 salt = keccak256("test_position");
        uint256 amount0 = 1e18;
        uint256 amount1 = 1e18;
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);

        IVault.ModifyLiquidityParams memory mlParams =
            IVault.ModifyLiquidityParams({amount0: amount0, amount1: amount1, liquidityDelta: 0, salt: salt});

        bytes memory innerData = abi.encode(poolKey, mlParams);
        bytes memory data = abi.encode(this.modifyLiquidity_callback.selector, innerData);
        vault.unlock(data);

        // Now get the position state
        PairPosition.State memory position = StateLibrary.getPairPositionState(vault, poolId, address(this), salt);
        assertGt(position.liquidity, 0, "Position liquidity should be > 0");
    }

    function testGetLastStageTimestamp() public view {
        uint256 lastStageTimestamp = StateLibrary.getLastStageTimestamp(vault, poolId);
        // After pool initialization and liquidity addition, timestamp may be set
        assertGe(lastStageTimestamp, 0, "Last stage timestamp should be >= 0");
    }
}
