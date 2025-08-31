// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {StateLibrary} from "../../src/libraries/StateLibrary.sol";
import {Pool} from "../../src/libraries/Pool.sol";
import {LikwidVault} from "../../src/LikwidVault.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../../src/types/PoolId.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {Slot0Library} from "../../src/types/Slot0.sol";
import {Reserves} from "../../src/types/Reserves.sol";

contract StateLibraryTest is Test {
    using PoolIdLibrary for PoolKey;
    using Slot0Library for Pool.State;

    LikwidVault vault;
    PoolKey poolKey;
    PoolId poolId;

    Currency currency0;
    Currency currency1;

    function setUp() public {
        vault = new LikwidVault(address(this));
        currency0 = Currency.wrap(address(0x1));
        currency1 = Currency.wrap(address(0x2));
        poolKey = PoolKey(currency0, currency1, 2400);
        poolId = poolKey.toId();
        vault.initialize(poolKey);
    }

    function testGetSlot0() public view {
        (uint128 totalSupply, uint32 lastUpdated, uint24 protocolFee, uint24 lpFee, uint24 marginFee) = StateLibrary.getSlot0(vault, poolId);

        assertTrue(totalSupply == 0);
        assertTrue(lastUpdated > 0);
        assertTrue(protocolFee == 0);
        assertTrue(lpFee == 2400);
        assertTrue(marginFee == 0);
    }

    function testGetBorrowDepositCumulative() public view {
        (uint256 borrow0CumulativeLast, uint256 borrow1CumulativeLast, uint256 deposit0CumulativeLast, uint256 deposit1CumulativeLast) = StateLibrary.getBorrowDepositCumulative(vault, poolId);

        assertEq(borrow0CumulativeLast, 1 << 96);
        assertEq(borrow1CumulativeLast, 1 << 96);
        assertEq(deposit0CumulativeLast, 1 << 96);
        assertEq(deposit1CumulativeLast, 1 << 96);
    }

    function testGetPairReserves() public view {
        Reserves reserves = StateLibrary.getPairReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = reserves.reserves();
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);
    }

    function testGetRealReserves() public view {
        Reserves reserves = StateLibrary.getRealReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = reserves.reserves();
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);
    }

    function testGetMirrorReserves() public view {
        Reserves reserves = StateLibrary.getMirrorReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = reserves.reserves();
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);
    }

    function testGetTruncatedReserves() public view {
        Reserves reserves = StateLibrary.getTruncatedReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = reserves.reserves();
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);
    }

    function testGetLendReserves() public view {
        Reserves reserves = StateLibrary.getLendReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = reserves.reserves();
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);
    }

    function testGetInterestReserves() public view {
        Reserves reserves = StateLibrary.getInterestReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = reserves.reserves();
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);
    }
}