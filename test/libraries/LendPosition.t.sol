// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendPosition} from "../../src/libraries/LendPosition.sol";
import {BalanceDelta, toBalanceDelta} from "../../src/types/BalanceDelta.sol";
import {PositionLibrary} from "../../src/libraries/PositionLibrary.sol";

// Wrapper contract to test reverts
contract LendPositionWrapper {
    using LendPosition for mapping(bytes32 => LendPosition.State);
    using PositionLibrary for address;

    mapping(bytes32 => LendPosition.State) public positions;

    function get(address owner, bool lendForOne, bytes32 salt)
        external
        view
        returns (uint128 lendAmount, uint256 depositCumulativeLast)
    {
        LendPosition.State storage position = positions.get(owner, lendForOne, salt);
        return (position.lendAmount, position.depositCumulativeLast);
    }

    function update(address owner, bool lendForOne, bytes32 salt, uint256 depositCumulativeLast, BalanceDelta delta)
        external
        returns (uint256)
    {
        LendPosition.State storage position = positions.get(owner, lendForOne, salt);
        return LendPosition.update(position, lendForOne, depositCumulativeLast, delta);
    }
}

contract LendPositionTest is Test {
    using LendPosition for mapping(bytes32 => LendPosition.State);
    using PositionLibrary for address;

    mapping(bytes32 => LendPosition.State) positions;
    LendPositionWrapper wrapper;
    address owner;
    bytes32 salt;

    function setUp() public {
        owner = address(0x123);
        salt = keccak256("test_salt");
        wrapper = new LendPositionWrapper();
    }

    function testGetPosition() public view {
        LendPosition.State storage position = positions.get(owner, false, salt);

        // Initially should be empty
        assertEq(position.lendAmount, 0, "Initial lend amount should be 0");
        assertEq(position.depositCumulativeLast, 0, "Initial deposit cumulative should be 0");
    }

    function testGetPositionDifferentSalts() public {
        bytes32 salt1 = keccak256("salt1");
        bytes32 salt2 = keccak256("salt2");

        LendPosition.State storage position1 = positions.get(owner, false, salt1);
        LendPosition.State storage position2 = positions.get(owner, false, salt2);

        // Should be different storage locations - check by verifying they are independent
        position1.lendAmount = 100;
        position2.lendAmount = 200;

        assertEq(positions.get(owner, false, salt1).lendAmount, 100, "Position1 should have independent value");
        assertEq(positions.get(owner, false, salt2).lendAmount, 200, "Position2 should have independent value");
    }

    function testGetPositionDifferentOwners() public {
        address owner1 = address(0x111);
        address owner2 = address(0x222);

        LendPosition.State storage position1 = positions.get(owner1, false, salt);
        LendPosition.State storage position2 = positions.get(owner2, false, salt);

        // Should be different storage locations - check by verifying they are independent
        position1.lendAmount = 100;
        position2.lendAmount = 200;

        assertEq(positions.get(owner1, false, salt).lendAmount, 100, "Position1 should have independent value");
        assertEq(positions.get(owner2, false, salt).lendAmount, 200, "Position2 should have independent value");
    }

    function testGetPositionDifferentDirections() public {
        LendPosition.State storage position0 = positions.get(owner, false, salt);
        LendPosition.State storage position1 = positions.get(owner, true, salt);

        // Should be different storage locations - check by verifying they are independent
        position0.lendAmount = 100;
        position1.lendAmount = 200;

        assertEq(positions.get(owner, false, salt).lendAmount, 100, "Position0 should have independent value");
        assertEq(positions.get(owner, true, salt).lendAmount, 200, "Position1 should have independent value");
    }

    function testUpdateDeposit() public {
        uint256 depositCumulativeLast = 1e18;
        int128 depositAmount = -100e18; // Negative means deposit

        BalanceDelta delta = toBalanceDelta(depositAmount, 0);

        // Get position and update directly using library function
        LendPosition.State storage position = positions.get(owner, false, salt);
        uint256 newLendAmount = LendPosition.update(position, false, depositCumulativeLast, delta);

        assertEq(newLendAmount, uint128(-depositAmount), "Lend amount should equal deposited amount");
        assertEq(position.lendAmount, uint128(-depositAmount), "Position lend amount should be updated");
        assertEq(position.depositCumulativeLast, depositCumulativeLast, "Deposit cumulative should be updated");
    }

    function testUpdateDepositForOne() public {
        uint256 depositCumulativeLast = 1e18;
        int128 depositAmount = -100e18; // Negative means deposit

        BalanceDelta delta = toBalanceDelta(0, depositAmount);

        // Get position and update directly using library function
        LendPosition.State storage position = positions.get(owner, true, salt);
        uint256 newLendAmount = LendPosition.update(position, true, depositCumulativeLast, delta);

        assertEq(newLendAmount, uint128(-depositAmount), "Lend amount should equal deposited amount");
        assertEq(position.lendAmount, uint128(-depositAmount), "Position lend amount should be updated");
    }

    function testUpdateWithdraw() public {
        // First deposit
        uint256 initialDepositCumulative = 1e18;
        int128 depositAmount = -100e18;

        BalanceDelta depositDelta = toBalanceDelta(depositAmount, 0);
        LendPosition.State storage position = positions.get(owner, false, salt);
        LendPosition.update(position, false, initialDepositCumulative, depositDelta);

        // Then withdraw
        uint256 withdrawCumulative = 1.1e18; // Increased cumulative
        int128 withdrawAmount = 50e18; // Positive means withdraw

        BalanceDelta withdrawDelta = toBalanceDelta(withdrawAmount, 0);
        uint256 newLendAmount = LendPosition.update(position, false, withdrawCumulative, withdrawDelta);

        // After withdrawal, lend amount should be reduced
        assertLt(newLendAmount, uint128(-depositAmount), "Lend amount should be reduced after withdrawal");
    }

    function testUpdateRemoveAllLiquidity() public {
        // First add liquidity
        uint256 depositCumulative = 1e18;
        LendPosition.State storage position = positions.get(owner, false, salt);
        LendPosition.update(position, false, depositCumulative, toBalanceDelta(-100e18, 0));

        // Then remove all liquidity
        BalanceDelta delta = toBalanceDelta(100e18, 0);

        LendPosition.update(position, false, depositCumulative, delta);

        assertEq(position.lendAmount, 0, "Lend amount should be zero");
    }

    function testCannotUpdateEmptyPosition() public {
        // Try to update with zero delta and empty position
        vm.expectRevert(LendPosition.CannotUpdateEmptyPosition.selector);
        wrapper.update(owner, false, salt, 1e18, toBalanceDelta(0, 0));
    }

    function testUpdateZeroDeltaWithExistingPosition() public {
        // First add liquidity to create position
        uint256 depositCumulative = 1e18;
        wrapper.update(owner, false, salt, depositCumulative, toBalanceDelta(-100e18, 0));

        // Update with zero amount in delta (should revert)
        vm.expectRevert(LendPosition.CannotUpdateEmptyPosition.selector);
        wrapper.update(owner, false, salt, depositCumulative, toBalanceDelta(0, 0));
    }

    function testWithdrawOverflow() public {
        // Deposit small amount
        uint256 depositCumulative = 1e18;
        wrapper.update(owner, false, salt, depositCumulative, toBalanceDelta(-10e18, 0));

        // Try to withdraw more than deposited
        vm.expectRevert(LendPosition.WithdrawOverflow.selector);
        wrapper.update(owner, false, salt, depositCumulative, toBalanceDelta(100e18, 0));
    }

    function testMultipleDeposits() public {
        uint256 depositCumulative = 1e18;
        LendPosition.State storage position = positions.get(owner, false, salt);

        // Multiple deposits
        int128 deposit1 = -50e18;
        int128 deposit2 = -30e18;
        int128 deposit3 = -20e18;

        LendPosition.update(position, false, depositCumulative, toBalanceDelta(deposit1, 0));
        LendPosition.update(position, false, depositCumulative, toBalanceDelta(deposit2, 0));
        uint256 finalAmount = LendPosition.update(position, false, depositCumulative, toBalanceDelta(deposit3, 0));

        assertEq(finalAmount, 100e18, "Final amount should be sum of all deposits");
    }

    function testPositionKeyCalculation() public pure {
        address testOwner = address(0x123);
        bool lendForOne = false;
        bytes32 testSalt = keccak256("test");

        bytes32 key1 = testOwner.calculatePositionKey(lendForOne, testSalt);
        bytes32 key2 = testOwner.calculatePositionKey(lendForOne, testSalt);

        assertEq(key1, key2, "Same inputs should produce same key");

        bytes32 key3 = testOwner.calculatePositionKey(!lendForOne, testSalt);
        assertNotEq(key1, key3, "Different lendForOne should produce different key");
    }
}
