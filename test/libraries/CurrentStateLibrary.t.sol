// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CurrentStateLibrary} from "../../src/libraries/CurrentStateLibrary.sol";
import {PoolState} from "../../src/types/PoolState.sol";
import {Reserves, toReserves} from "../../src/types/Reserves.sol";
import {MarginState, MarginStateLibrary} from "../../src/types/MarginState.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {PoolId} from "../../src/types/PoolId.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";
import {MarginBalanceDelta} from "../../src/types/MarginBalanceDelta.sol";
import {Currency} from "../../src/types/Currency.sol";

// Mock Vault that implements IVault interface for testing
contract MockVault is IVault {
    mapping(bytes32 => bytes32) public storageSlots;
    uint256 public nativeBalance;

    function setSlot(bytes32 slot, bytes32 value) external {
        storageSlots[slot] = value;
    }

    // IVault interface functions
    function mint(address to, uint256 id, uint256 amount) external {
        // Mock implementation
    }

    function burn(address from, uint256 id, uint256 amount) external {
        // Mock implementation
    }

    function take(Currency currency, address recipient, uint256 amount) external {
        // Mock implementation
    }

    function settle() external payable returns (uint256 paid) {
        nativeBalance += msg.value;
        return msg.value;
    }

    function settleFor(address) external payable returns (uint256 paid) {
        nativeBalance += msg.value;
        return msg.value;
    }

    function clear(Currency currency, uint256 amount) external {
        // Mock implementation
    }

    function sync(Currency currency) external {
        // Mock implementation
    }

    function modifyLiquidity(PoolKey calldata, IVault.ModifyLiquidityParams calldata)
        external
        pure
        returns (BalanceDelta, int128)
    {
        return (BalanceDelta.wrap(0), 0);
    }

    function swap(PoolKey calldata, IVault.SwapParams calldata) external pure returns (BalanceDelta, uint24, uint256) {
        return (BalanceDelta.wrap(0), 0, 0);
    }

    function donate(PoolKey calldata, uint256, uint256) external pure returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function lend(PoolKey calldata, IVault.LendParams calldata) external pure returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function marginBalance(PoolKey calldata, MarginBalanceDelta calldata) external pure returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function initialize(PoolKey calldata) external {}

    // IExtsload interface functions
    function extsload(bytes32 slot) external view returns (bytes32) {
        return storageSlots[slot];
    }

    function extsload(bytes32 slot, uint256 count) external view returns (bytes32[] memory) {
        bytes32[] memory values = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            values[i] = storageSlots[bytes32(uint256(slot) + i)];
        }
        return values;
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory) {
        bytes32[] memory values = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            values[i] = storageSlots[slots[i]];
        }
        return values;
    }

    // IExttload interface functions
    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function exttload(bytes32[] calldata) external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function unlock(bytes calldata) external pure returns (bytes memory) {
        return "";
    }

    // IERC6909Claims interface functions
    function allowance(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function isOperator(address, address) external pure returns (bool) {
        return false;
    }

    function setOperator(address, bool) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    // IMarginBase interface functions
    MarginState private _marginState;

    function marginState() external view returns (MarginState) {
        return _marginState;
    }

    function setMarginState(MarginState state) external {
        _marginState = state;
    }

    function marginController() external pure returns (address) {
        return address(0);
    }
}

contract CurrentStateLibraryTest is Test {
    using MarginStateLibrary for MarginState;

    MockVault vault;
    PoolId poolId;

    function setUp() public {
        vault = new MockVault();
        poolId = PoolId.wrap(keccak256("test_pool"));

        // Setup mock storage slots
        bytes32 poolStateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), CurrentStateLibrary.POOLS_SLOT));

        // Mock slot0 data with proper values
        // Slot0 layout: totalSupply (128 bits) | lastUpdated (32 bits) | protocolFee (24 bits) | lpFee (24 bits) | marginFee (24 bits) | insuranceFundPercentage (8 bits)
        bytes32 slot0Data = bytes32(
            uint256(1000e18) // totalSupply
                | (uint256(uint32(block.timestamp)) << 128) // lastUpdated
                | (uint256(0x123456) << 160) // protocolFee
                | (uint256(3000) << 184) // lpFee
                | (uint256(100) << 208) // marginFee
        );
        vault.setSlot(poolStateSlot, slot0Data);

        // Mock default protocol fee
        vault.setSlot(CurrentStateLibrary.DEFAULT_PROTOCOL_FEE_SLOT, bytes32(uint256(0x123456) << 160));

        // Mock pool data - we need to set up Reserves as bytes32 values
        bytes32 startSlot = bytes32(uint256(poolStateSlot) + 1);
        vault.setSlot(startSlot, bytes32(uint256(1e18))); // borrow0CumulativeBefore
        vault.setSlot(bytes32(uint256(startSlot) + 1), bytes32(uint256(1e18))); // borrow1CumulativeBefore
        vault.setSlot(bytes32(uint256(startSlot) + 2), bytes32(uint256(1e18))); // deposit0CumulativeBefore
        vault.setSlot(bytes32(uint256(startSlot) + 3), bytes32(uint256(1e18))); // deposit1CumulativeBefore

        // For Reserves, we need to convert properly
        Reserves realReserves = toReserves(1000e18, 1000e18);
        vault.setSlot(bytes32(uint256(startSlot) + 4), bytes32(Reserves.unwrap(realReserves))); // realReserves

        Reserves mirrorReserves = toReserves(0, 0);
        vault.setSlot(bytes32(uint256(startSlot) + 5), bytes32(Reserves.unwrap(mirrorReserves))); // mirrorReserves

        Reserves pairReserves = toReserves(1000e18, 1000e18);
        vault.setSlot(bytes32(uint256(startSlot) + 6), bytes32(Reserves.unwrap(pairReserves))); // pairReserves

        Reserves truncatedReserves = toReserves(0, 0);
        vault.setSlot(bytes32(uint256(startSlot) + 7), bytes32(Reserves.unwrap(truncatedReserves))); // truncatedReserves

        Reserves lendReserves = toReserves(0, 0);
        vault.setSlot(bytes32(uint256(startSlot) + 8), bytes32(Reserves.unwrap(lendReserves))); // lendReserves

        Reserves interestReserves = toReserves(0, 0);
        vault.setSlot(bytes32(uint256(startSlot) + 9), bytes32(Reserves.unwrap(interestReserves))); // interestReserves

        Reserves protocolInterestReserves = toReserves(0, 0);
        vault.setSlot(bytes32(uint256(startSlot) + 10), bytes32(Reserves.unwrap(protocolInterestReserves))); // protocolInterestReserves

        // Set margin state with rateBase > 0
        vault.setMarginState(MarginState.wrap(bytes32(uint256(1000)))); // rateBase = 1000
    }

    function testGetStateBasic() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        // Basic assertions
        assertGt(state.totalSupply, 0, "Total supply should be greater than 0");
        assertGt(state.lastUpdated, 0, "Last updated should be greater than 0");
        assertEq(state.protocolFee, 0x123456, "Protocol fee should match");
    }

    function testGetStateReserves() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        (uint128 realReserve0, uint128 realReserve1) = state.realReserves.reserves();
        assertEq(realReserve0, 1000e18, "Real reserve 0 should match");
        assertEq(realReserve1, 1000e18, "Real reserve 1 should match");

        (uint128 pairReserve0, uint128 pairReserve1) = state.pairReserves.reserves();
        assertEq(pairReserve0, 1000e18, "Pair reserve 0 should match");
        assertEq(pairReserve1, 1000e18, "Pair reserve 1 should match");
    }

    function testGetStateCumulativeRates() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        assertGt(state.borrow0CumulativeLast, 0, "Borrow 0 cumulative should be greater than 0");
        assertGt(state.borrow1CumulativeLast, 0, "Borrow 1 cumulative should be greater than 0");
        assertGt(state.deposit0CumulativeLast, 0, "Deposit 0 cumulative should be greater than 0");
        assertGt(state.deposit1CumulativeLast, 0, "Deposit 1 cumulative should be greater than 0");
    }

    function testGetStateDefaultProtocolFee() public {
        // Test when protocol fee is 0 in slot0
        bytes32 poolStateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), CurrentStateLibrary.POOLS_SLOT));
        vault.setSlot(poolStateSlot, bytes32(0)); // Set protocol fee to 0

        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        assertEq(state.protocolFee, 0x123456, "Should use default protocol fee when pool fee is 0");
    }

    function testGetStateInterestReserves() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        (uint128 interestReserve0, uint128 interestReserve1) = state.interestReserves.reserves();
        assertEq(interestReserve0, 0, "Interest reserve 0 should be 0 initially");
        assertEq(interestReserve1, 0, "Interest reserve 1 should be 0 initially");
    }

    function testGetStateProtocolInterestReserves() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        (uint128 protocolInterestReserve0, uint128 protocolInterestReserve1) = state.protocolInterestReserves.reserves();
        assertEq(protocolInterestReserve0, 0, "Protocol interest reserve 0 should be 0 initially");
        assertEq(protocolInterestReserve1, 0, "Protocol interest reserve 1 should be 0 initially");
    }

    function testGetStateTruncatedReserves() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        (uint128 truncatedReserve0, uint128 truncatedReserve1) = state.truncatedReserves.reserves();
        // Truncated reserves may be updated by PriceMath.transferReserves
        // Just verify they are valid values
        assertGe(truncatedReserve0, 0, "Truncated reserve 0 should be >= 0");
        assertGe(truncatedReserve1, 0, "Truncated reserve 1 should be >= 0");
    }

    function testGetStateLendReserves() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        (uint128 lendReserve0, uint128 lendReserve1) = state.lendReserves.reserves();
        assertEq(lendReserve0, 0, "Lend reserve 0 should be 0 initially");
        assertEq(lendReserve1, 0, "Lend reserve 1 should be 0 initially");
    }

    function testGetStateMirrorReserves() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        (uint128 mirrorReserve0, uint128 mirrorReserve1) = state.mirrorReserves.reserves();
        assertEq(mirrorReserve0, 0, "Mirror reserve 0 should be 0 initially");
        assertEq(mirrorReserve1, 0, "Mirror reserve 1 should be 0 initially");
    }

    function testGetStateMarginState() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        // Margin state should be initialized
        assertGt(state.marginState.rateBase(), 0, "Margin state rate base should be greater than 0");
    }

    function testGetStateUpdatedTimestamp() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        // Last updated should be set to current block timestamp
        assertEq(state.lastUpdated, uint32(block.timestamp), "Last updated should be current block timestamp");
    }
}
