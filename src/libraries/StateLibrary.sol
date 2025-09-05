// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "../types/PoolId.sol";
import {IVault} from "../interfaces/IVault.sol";
import {Slot0, Slot0Library} from "../types/Slot0.sol";
import {Reserves, ReservesLibrary} from "../types/Reserves.sol";
import {PairPosition} from "./PairPosition.sol";
import {LendPosition} from "./LendPosition.sol";
import {MarginPosition} from "./MarginPosition.sol";
import {PositionLibrary} from "./PositionLibrary.sol";

/// @title A helper library to provide state getters for a Likwid pool
/// @notice This library provides functions to read the state of a Likwid pool from storage.
library StateLibrary {
    using Slot0Library for Slot0;
    using ReservesLibrary for Reserves;
    using PositionLibrary for address;

    /// @notice The storage slot of the `_pools` mapping in the LikwidVault contract.
    bytes32 public constant POOLS_SLOT = bytes32(uint256(7));

    // Offsets for fields within the Pool.State struct
    uint256 internal constant BORROW_0_CUMULATIVE_LAST_OFFSET = 1;
    uint256 internal constant BORROW_1_CUMULATIVE_LAST_OFFSET = 2;
    uint256 internal constant DEPOSIT_0_CUMULATIVE_LAST_OFFSET = 3;
    uint256 internal constant DEPOSIT_1_CUMULATIVE_LAST_OFFSET = 4;
    uint256 internal constant REAL_RESERVES_OFFSET = 5;
    uint256 internal constant MIRROR_RESERVES_OFFSET = 6;
    uint256 internal constant PAIR_RESERVES_OFFSET = 7;
    uint256 internal constant TRUNCATED_RESERVES_OFFSET = 8;
    uint256 internal constant LEND_RESERVES_OFFSET = 9;
    uint256 internal constant INTEREST_RESERVES_OFFSET = 10;
    uint256 internal constant POSITIONS_OFFSET = 11;
    uint256 internal constant LEND_POSITIONS_OFFSET = 12;
    uint256 internal constant MARGIN_POSITIONS_OFFSET = 13;

    /**
     * @notice Get the unpacked Slot0 of the pool.
     * @dev Corresponds to pools[poolId].slot0
     * @param manager The vault contract.
     * @param poolId The ID of the pool.
     * @return totalSupply The total supply of liquidity tokens.
     * @return lastUpdated The timestamp of the last update.
     * @return protocolFee The protocol fee of the pool.
     * @return lpFee The swap fee of the pool.
     * @return marginFee The margin fee of the pool.
     */
    function getSlot0(IVault manager, PoolId poolId)
        internal
        view
        returns (uint128 totalSupply, uint32 lastUpdated, uint24 protocolFee, uint24 lpFee, uint24 marginFee)
    {
        bytes32 stateSlot = _getPoolStateSlot(poolId);
        Slot0 slot0 = Slot0.wrap(manager.extsload(stateSlot));

        totalSupply = slot0.totalSupply();
        lastUpdated = slot0.lastUpdated();
        protocolFee = slot0.protocolFee();
        lpFee = slot0.lpFee();
        marginFee = slot0.marginFee();
    }

    /**
     * @notice Retrieves the cumulative borrow and deposit rates of a pool.
     * @param manager The vault contract.
     * @param poolId The ID of the pool.
     * @return borrow0CumulativeLast The cumulative borrow rate for currency 0.
     * @return borrow1CumulativeLast The cumulative borrow rate for currency 1.
     * @return deposit0CumulativeLast The cumulative deposit rate for currency 0.
     * @return deposit1CumulativeLast The cumulative deposit rate for currency 1.
     */
    function getBorrowDepositCumulative(IVault manager, PoolId poolId)
        internal
        view
        returns (
            uint256 borrow0CumulativeLast,
            uint256 borrow1CumulativeLast,
            uint256 deposit0CumulativeLast,
            uint256 deposit1CumulativeLast
        )
    {
        bytes32 stateSlot = _getPoolStateSlot(poolId);
        bytes32 startSlot = bytes32(uint256(stateSlot) + BORROW_0_CUMULATIVE_LAST_OFFSET);

        bytes32[] memory data = manager.extsload(startSlot, 4);
        assembly ("memory-safe") {
            borrow0CumulativeLast := mload(add(data, 0x20))
            borrow1CumulativeLast := mload(add(data, 0x40))
            deposit0CumulativeLast := mload(add(data, 0x60))
            deposit1CumulativeLast := mload(add(data, 0x80))
        }
    }

    /**
     * @notice Retrieves the pair reserves of a pool.
     * @param manager The vault contract.
     * @param poolId The ID of the pool.
     * @return The packed pair reserves of the pool.
     */
    function getPairReserves(IVault manager, PoolId poolId) internal view returns (Reserves) {
        bytes32 slot = bytes32(uint256(_getPoolStateSlot(poolId)) + PAIR_RESERVES_OFFSET);
        return Reserves.wrap(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Retrieves the real reserves of a pool.
     * @param manager The vault contract.
     * @param poolId The ID of the pool.
     * @return The packed real reserves of the pool.
     */
    function getRealReserves(IVault manager, PoolId poolId) internal view returns (Reserves) {
        bytes32 slot = bytes32(uint256(_getPoolStateSlot(poolId)) + REAL_RESERVES_OFFSET);
        return Reserves.wrap(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Retrieves the mirror reserves of a pool.
     * @param manager The vault contract.
     * @param poolId The ID of the pool.
     * @return The packed mirror reserves of the pool.
     */
    function getMirrorReserves(IVault manager, PoolId poolId) internal view returns (Reserves) {
        bytes32 slot = bytes32(uint256(_getPoolStateSlot(poolId)) + MIRROR_RESERVES_OFFSET);
        return Reserves.wrap(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Retrieves the truncated reserves of a pool.
     * @param manager The vault contract.
     * @param poolId The ID of the pool.
     * @return The packed truncated reserves of the pool.
     */
    function getTruncatedReserves(IVault manager, PoolId poolId) internal view returns (Reserves) {
        bytes32 slot = bytes32(uint256(_getPoolStateSlot(poolId)) + TRUNCATED_RESERVES_OFFSET);
        return Reserves.wrap(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Retrieves the lending reserves of a pool.
     * @param manager The vault contract.
     * @param poolId The ID of the pool.
     * @return The packed lending reserves of the pool.
     */
    function getLendReserves(IVault manager, PoolId poolId) internal view returns (Reserves) {
        bytes32 slot = bytes32(uint256(_getPoolStateSlot(poolId)) + LEND_RESERVES_OFFSET);
        return Reserves.wrap(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Retrieves the interest reserves of a pool.
     * @param manager The vault contract.
     * @param poolId The ID of the pool.
     * @return The packed interest reserves of the pool.
     */
    function getInterestReserves(IVault manager, PoolId poolId) internal view returns (Reserves) {
        bytes32 slot = bytes32(uint256(_getPoolStateSlot(poolId)) + INTEREST_RESERVES_OFFSET);
        return Reserves.wrap(uint256(manager.extsload(slot)));
    }

    function getPairPositionState(IVault manager, PoolId poolId, address owner, bytes32 salt)
        internal
        view
        returns (PairPosition.State memory _position)
    {
        bytes32 positionKey = owner.calculatePositionKey(salt);

        bytes32 poolStateSlot = _getPoolStateSlot(poolId);
        bytes32 positionsMappingSlot = bytes32(uint256(poolStateSlot) + POSITIONS_OFFSET);
        bytes32 positionSlot = keccak256(abi.encodePacked(positionKey, positionsMappingSlot));

        bytes32[] memory data = manager.extsload(positionSlot, 2);
        _position.liquidity = uint128(uint256(data[0]));
        _position.totalInvestment = uint256(data[1]);
    }

    function getLendPositionState(IVault manager, PoolId poolId, address owner, bool lendForOne, bytes32 salt)
        internal
        view
        returns (LendPosition.State memory _position)
    {
        bytes32 positionKey = owner.calculatePositionKey(lendForOne, salt);

        bytes32 poolStateSlot = _getPoolStateSlot(poolId);
        bytes32 positionsMappingSlot = bytes32(uint256(poolStateSlot) + LEND_POSITIONS_OFFSET);
        bytes32 positionSlot = keccak256(abi.encodePacked(positionKey, positionsMappingSlot));

        bytes32[] memory data = manager.extsload(positionSlot, 2);
        uint256 slot0 = uint256(data[0]);
        _position.lendForOne = uint8(slot0) == 1;
        _position.lendAmount = uint128(slot0 >> 8);
        _position.depositCumulativeLast = uint256(data[1]);
    }

    function getMarginPositionState(IVault manager, PoolId poolId, address owner, bool marginForOne, bytes32 salt)
        internal
        view
        returns (MarginPosition.State memory _position)
    {
        bytes32 positionKey = owner.calculatePositionKey(marginForOne, salt);

        bytes32 poolStateSlot = _getPoolStateSlot(poolId);
        bytes32 positionsMappingSlot = bytes32(uint256(poolStateSlot) + MARGIN_POSITIONS_OFFSET);
        bytes32 positionSlot = keccak256(abi.encodePacked(positionKey, positionsMappingSlot));

        bytes32[] memory data = manager.extsload(positionSlot, 4);
        uint256 slot0 = uint256(data[0]);
        _position.marginForOne = uint8(slot0) == 1;
        _position.marginAmount = uint128(slot0 >> 8);

        uint256 slot1 = uint256(data[1]);
        _position.marginTotal = uint128(slot1);
        _position.debtAmount = uint128(slot1 >> 128);

        _position.borrowCumulativeLast = uint256(data[2]);
        _position.depositCumulativeLast = uint256(data[3]);
    }

    /**
     * @notice Calculates the storage slot for a specific pool's state.
     * @param poolId The ID of the pool.
     * @return The storage slot of the Pool.State struct.
     */
    function _getPoolStateSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));
    }
}
