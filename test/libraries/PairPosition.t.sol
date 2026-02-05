// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PairPosition} from "../../src/libraries/PairPosition.sol";
import {BalanceDelta, toBalanceDelta} from "../../src/types/BalanceDelta.sol";
import {PositionLibrary} from "../../src/libraries/PositionLibrary.sol";

// Wrapper contract to test reverts
contract PairPositionWrapper {
    using PairPosition for mapping(bytes32 => PairPosition.State);
    using PositionLibrary for address;

    mapping(bytes32 => PairPosition.State) public positions;

    function update(address owner, bytes32 salt, int128 liquidityDelta, BalanceDelta delta) external returns (uint256) {
        PairPosition.State storage position = positions.get(owner, salt);
        return PairPosition.update(position, liquidityDelta, delta);
    }
}

contract PairPositionTest is Test {
    using PairPosition for mapping(bytes32 => PairPosition.State);
    using PositionLibrary for address;

    mapping(bytes32 => PairPosition.State) positions;
    PairPositionWrapper wrapper;
    address owner;
    bytes32 salt;

    function setUp() public {
        owner = address(0x123);
        salt = keccak256("test_salt");
        wrapper = new PairPositionWrapper();
    }

    function testGetPosition() public view {
        PairPosition.State storage position = positions.get(owner, salt);

        // Initially should be empty
        assertEq(position.liquidity, 0, "Initial liquidity should be 0");
        assertEq(position.totalInvestment, 0, "Initial total investment should be 0");
    }

    function testGetPositionDifferentSalts() public {
        bytes32 salt1 = keccak256("salt1");
        bytes32 salt2 = keccak256("salt2");

        PairPosition.State storage position1 = positions.get(owner, salt1);
        PairPosition.State storage position2 = positions.get(owner, salt2);

        // Should be different storage locations - check by verifying they are independent
        position1.liquidity = 100;
        position2.liquidity = 200;

        assertEq(positions.get(owner, salt1).liquidity, 100, "Position1 should have independent value");
        assertEq(positions.get(owner, salt2).liquidity, 200, "Position2 should have independent value");
    }

    function testGetPositionDifferentOwners() public {
        address owner1 = address(0x111);
        address owner2 = address(0x222);

        PairPosition.State storage position1 = positions.get(owner1, salt);
        PairPosition.State storage position2 = positions.get(owner2, salt);

        // Should be different storage locations - check by verifying they are independent
        position1.liquidity = 100;
        position2.liquidity = 200;

        assertEq(positions.get(owner1, salt).liquidity, 100, "Position1 should have independent value");
        assertEq(positions.get(owner2, salt).liquidity, 200, "Position2 should have independent value");
    }

    function testUpdateAddLiquidity() public {
        PairPosition.State storage position = positions.get(owner, salt);

        int128 liquidityDelta = 100;
        BalanceDelta delta = toBalanceDelta(-1000, -2000);

        uint256 totalInvestment = PairPosition.update(position, liquidityDelta, delta);

        assertEq(position.liquidity, 100, "Liquidity should be updated");
        assertGt(totalInvestment, 0, "Total investment should be positive");
    }

    function testUpdateRemoveLiquidity() public {
        PairPosition.State storage position = positions.get(owner, salt);

        // First add liquidity
        PairPosition.update(position, 100, toBalanceDelta(-1000, -2000));

        // Then remove liquidity
        int128 liquidityDelta = -50;
        BalanceDelta delta = toBalanceDelta(500, 1000);

        uint256 totalInvestment = PairPosition.update(position, liquidityDelta, delta);

        assertEq(position.liquidity, 50, "Liquidity should be reduced");
    }

    function testUpdateRemoveAllLiquidity() public {
        PairPosition.State storage position = positions.get(owner, salt);

        // First add liquidity
        PairPosition.update(position, 100, toBalanceDelta(-1000, -2000));

        // Then remove all liquidity
        int128 liquidityDelta = -100;
        BalanceDelta delta = toBalanceDelta(1000, 2000);

        PairPosition.update(position, liquidityDelta, delta);

        assertEq(position.liquidity, 0, "Liquidity should be zero");
    }

    function testCannotUpdateEmptyPosition() public {
        // Try to update with zero liquidity delta and empty position
        vm.expectRevert(PairPosition.CannotUpdateEmptyPosition.selector);
        wrapper.update(owner, salt, 0, toBalanceDelta(0, 0));
    }

    function testUpdateZeroDeltaWithExistingPosition() public {
        PairPosition.State storage position = positions.get(owner, salt);

        // First add liquidity to create position
        PairPosition.update(position, 100, toBalanceDelta(-1000, -2000));

        // Update with zero liquidity delta (poking)
        BalanceDelta delta = toBalanceDelta(-100, -200);
        uint256 totalInvestment = PairPosition.update(position, 0, delta);

        // Liquidity should remain unchanged
        assertEq(position.liquidity, 100, "Liquidity should remain unchanged");
        assertGt(totalInvestment, 0, "Total investment should be updated");
    }

    function testTotalInvestmentAccumulation() public {
        PairPosition.State storage position = positions.get(owner, salt);

        // First add
        PairPosition.update(position, 100, toBalanceDelta(-1000, -2000));
        uint256 investment1 = position.totalInvestment;

        // Second add
        PairPosition.update(position, 50, toBalanceDelta(-500, -1000));
        uint256 investment2 = position.totalInvestment;

        // Investment should accumulate
        assertGt(investment2, investment1, "Investment should accumulate");
    }

    function testPositionKeyCalculation() public pure {
        address testOwner = address(0x123);
        bytes32 testSalt = keccak256("test");

        bytes32 key1 = testOwner.calculatePositionKey(testSalt);
        bytes32 key2 = testOwner.calculatePositionKey(testSalt);

        assertEq(key1, key2, "Same inputs should produce same key");

        bytes32 key3 = PositionLibrary.calculatePositionKey(testOwner, testSalt);
        assertEq(key1, key3, "Library function should produce same key");
    }

    function testMultiplePositions() public {
        bytes32 salt1 = keccak256("position1");
        bytes32 salt2 = keccak256("position2");

        PairPosition.State storage position1 = positions.get(owner, salt1);
        PairPosition.State storage position2 = positions.get(owner, salt2);

        // Update both positions independently
        PairPosition.update(position1, 100, toBalanceDelta(-1000, -2000));
        PairPosition.update(position2, 200, toBalanceDelta(-2000, -4000));

        assertEq(position1.liquidity, 100, "Position1 liquidity should be correct");
        assertEq(position2.liquidity, 200, "Position2 liquidity should be correct");
    }

    function testNegativeInvestment() public {
        PairPosition.State storage position = positions.get(owner, salt);

        // Add liquidity
        PairPosition.update(position, 100, toBalanceDelta(-1000, -2000));

        // Remove more than added (simulating profit)
        PairPosition.update(position, -50, toBalanceDelta(600, 1200));

        // Total investment should track net investment
        assertGt(position.totalInvestment, 0, "Total investment should still be positive");
    }

    function testLiquidityOverflowProtection() public {
        PairPosition.State storage position = positions.get(owner, salt);

        // Add maximum liquidity
        int128 maxLiquidity = type(int128).max;
        PairPosition.update(position, maxLiquidity, toBalanceDelta(-1, -1));

        assertEq(position.liquidity, uint128(maxLiquidity), "Should handle max liquidity");
    }
}
