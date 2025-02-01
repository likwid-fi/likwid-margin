// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {IMarginHookManager} from "./interfaces/IMarginHookManager.sol";
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

    struct ObservationQuery {
        PoolId id;
        address hook;
        uint32[] secondsAgos;
    }

    /// @notice The list of observations for a given pool ID
    mapping(address => mapping(PoolId => TruncatedOracle.Observation[65535])) public observations;
    /// @notice The current observation array state for the given pool ID
    mapping(address => mapping(PoolId => ObservationState)) public states;

    /// @notice Returns the state for the given pool key
    function getState(address hook, PoolKey calldata key) external view returns (ObservationState memory state) {
        state = states[hook][key.toId()];
    }

    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }

    function initialize(PoolKey calldata key, uint112 reserve0, uint112 reserve1) external {
        PoolId id = key.toId();
        address sender = address(key.hooks);
        (states[sender][id].cardinality, states[sender][id].cardinalityNext) =
            observations[sender][key.toId()].initialize(_blockTimestamp(), reserve0, reserve1);
    }

    function write(PoolKey calldata key, uint112 reserve0, uint112 reserve1) external {
        PoolId id = key.toId();
        address hook = address(key.hooks);
        require(hook == msg.sender, "ONLY_HOOK_CALL");
        ObservationState storage _state = states[hook][id];
        (_state.index, _state.cardinalityNext) = observations[hook][key.toId()].write(
            _state.index, _blockTimestamp(), reserve0, reserve1, _state.cardinality, _state.cardinalityNext
        );
    }

    function observeNow(PoolId id, address hook)
        external
        view
        returns (uint224 reserves, uint256 price1CumulativeLast)
    {
        IMarginHookManager hookManager = IMarginHookManager(hook);
        (uint256 reserve0, uint256 reserve1) = hookManager.getReserves(id);
        return observations[hook][id].observeSingle(
            _blockTimestamp(),
            0,
            uint112(reserve0),
            uint112(reserve1),
            states[hook][id].index,
            states[hook][id].cardinality
        );
    }

    /// @notice Observe the given pool for the timestamps
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (uint224[] memory reserves, uint256[] memory price1CumulativeLast)
    {
        PoolId id = key.toId();
        address sender = address(key.hooks);
        ObservationState memory state = states[sender][id];
        IMarginHookManager hook = IMarginHookManager(sender);
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(id);
        return observations[sender][id].observe(
            _blockTimestamp(), secondsAgos, uint112(reserve0), uint112(reserve1), state.index, state.cardinality
        );
    }

    /// @notice Increase the cardinality target for the given pool
    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        PoolId id = key.toId();
        address hook = address(key.hooks);
        ObservationState storage state = states[hook][id];

        cardinalityNextOld = state.cardinalityNext;
        cardinalityNextNew = observations[hook][id].grow(cardinalityNextOld, cardinalityNext);
        state.cardinalityNext = cardinalityNextNew;
    }
}
