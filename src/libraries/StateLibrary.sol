// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "../types/PoolId.sol";
import {IVault} from "../interfaces/IVault.sol";
import {Slot0, Slot0Library} from "../types/Slot0.sol";
import {Reserves, ReservesLibrary} from "../types/Reserves.sol";

/// @notice A helper library to provide state getters for a Likwid pool
library StateLibrary {
    using Slot0Library for Slot0;
    using ReservesLibrary for Reserves;

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
     * @return reserves The packed pair reserves of the pool.
     */
    function getPairReserves(IVault manager, PoolId poolId) internal view returns (Reserves) {
        bytes32 slot = bytes32(uint256(_getPoolStateSlot(poolId)) + PAIR_RESERVES_OFFSET);
        return Reserves.wrap(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Retrieves the real reserves of a pool.
     * @param manager The vault contract.
     * @param poolId The ID of the pool.
     * @return reserves The packed real reserves of the pool.
     */
    function getRealReserves(IVault manager, PoolId poolId) internal view returns (Reserves) {
        bytes32 slot = bytes32(uint256(_getPoolStateSlot(poolId)) + REAL_RESERVES_OFFSET);
        return Reserves.wrap(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Retrieves the mirror reserves of a pool.
     * @param manager The vault contract.
     * @param poolId The ID of the pool.
     * @return reserves The packed mirror reserves of the pool.
     */
    function getMirrorReserves(IVault manager, PoolId poolId) internal view returns (Reserves) {
        bytes32 slot = bytes32(uint256(_getPoolStateSlot(poolId)) + MIRROR_RESERVES_OFFSET);
        return Reserves.wrap(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Retrieves the truncated reserves of a pool.
     * @param manager The vault contract.
     * @param poolId The ID of the pool.
     * @return reserves The packed truncated reserves of the pool.
     */
    function getTruncatedReserves(IVault manager, PoolId poolId) internal view returns (Reserves) {
        bytes32 slot = bytes32(uint256(_getPoolStateSlot(poolId)) + TRUNCATED_RESERVES_OFFSET);
        return Reserves.wrap(uint256(manager.extsload(slot)));
    }

    /**
     * @notice Retrieves the lending reserves of a pool.
     * @param manager The vault contract.
     * @param poolId The ID of the pool.
     * @return reserves The packed lending reserves of the pool.
     */
    function getLendReserves(IVault manager, PoolId poolId) internal view returns (Reserves) {
        bytes32 slot = bytes32(uint256(_getPoolStateSlot(poolId)) + LEND_RESERVES_OFFSET);
        return Reserves.wrap(uint256(manager.extsload(slot)));
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
