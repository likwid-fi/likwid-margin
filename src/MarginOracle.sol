// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IMarginOracleReader} from "./interfaces/IMarginOracleReader.sol";
import {IMarginOracleWriter} from "./interfaces/IMarginOracleWriter.sol";

contract MarginOracle {
    using PoolIdLibrary for PoolKey;
    using TruncatedOracle for TruncatedOracle.Observation[65535];

    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    modifier onlyPairPoolManager(IHooks hooks) {
        require(IPairPoolManager(msg.sender).hooks() == hooks, "UNAUTHORIZED");
        _;
    }

    /// @notice The list of observations for a given pool ID
    mapping(address => mapping(PoolId => TruncatedOracle.Observation[65535])) public observations;
    /// @notice The current observation array state for the given pool ID
    mapping(address => mapping(PoolId => ObservationState)) public states;

    /// @notice Returns the state for the given pool key
    function getState(PoolKey calldata key) external view returns (ObservationState memory state) {
        state = states[address(key.hooks)][key.toId()];
    }

    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }

    function write(PoolKey calldata key, uint112 reserve0, uint112 reserve1) external onlyPairPoolManager(key.hooks) {
        PoolId id = key.toId();
        address hook = address(key.hooks);
        ObservationState storage _state = states[hook][id];
        if (_state.cardinality == 0) {
            (_state.cardinality, _state.cardinalityNext) =
                observations[hook][id].initialize(_blockTimestamp(), reserve0, reserve1);
        } else {
            if (reserve0 == 0 || reserve1 == 0) {
                delete states[hook][id];
            } else {
                (_state.index, _state.cardinality) = observations[hook][id].write(
                    _state.index, _blockTimestamp(), reserve0, reserve1, _state.cardinality, _state.cardinalityNext
                );
            }
        }
    }

    function observeNow(IPairPoolManager poolManager, PoolId id)
        external
        view
        returns (uint224 reserves, uint256 price1CumulativeLast)
    {
        address hook = address(poolManager.hooks());
        (uint256 reserve0, uint256 reserve1) = poolManager.getReserves(id);
        if (reserve0 > 0 && reserve1 > 0) {
            return observations[hook][id].observeSingle(
                _blockTimestamp(),
                0,
                uint112(reserve0),
                uint112(reserve1),
                states[hook][id].index,
                states[hook][id].cardinality
            );
        }
    }

    /// @notice Observe the given pool for the timestamps
    function observe(IPairPoolManager poolManager, PoolId id, uint32[] calldata secondsAgos)
        external
        view
        returns (uint224[] memory reserves, uint256[] memory price1CumulativeLast)
    {
        address hook = address(poolManager.hooks());
        ObservationState memory state = states[hook][id];
        (uint256 reserve0, uint256 reserve1) = poolManager.getReserves(id);
        if (reserve0 > 0 && reserve1 > 0) {
            TruncatedOracle.Observation[65535] storage ob = observations[hook][id];
            (reserves, price1CumulativeLast) = ob.observe(
                _blockTimestamp(), secondsAgos, uint112(reserve0), uint112(reserve1), state.index, state.cardinality
            );
        }
    }

    /// @notice Increase the cardinality target for the given pool
    function increaseCardinalityNext(IPairPoolManager poolManager, PoolId id, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        address hook = address(poolManager.hooks());
        ObservationState storage state = states[hook][id];

        cardinalityNextOld = state.cardinalityNext;
        cardinalityNextNew = observations[hook][id].grow(cardinalityNextOld, cardinalityNext);
        state.cardinalityNext = cardinalityNextNew;
    }
}
