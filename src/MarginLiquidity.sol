// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {DoubleEndedQueue} from "./external/openzeppelin-contracts/DoubleEndedQueue.sol";
// Local
import {ERC6909Liquidity} from "./base/ERC6909Liquidity.sol";
import {StageMath} from "./libraries/StageMath.sol";

import {PoolStatus, PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";
import {IStatusBase} from "./interfaces/IStatusBase.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";

contract MarginLiquidity is IMarginLiquidity, ERC6909Liquidity, Owned {
    using SafeCast for uint256;
    using StageMath for uint256;
    using PoolStatusLibrary for PoolStatus;
    using DoubleEndedQueue for DoubleEndedQueue.Uint256Deque;

    error LiquidityLocked();
    error PoolIsEmpty();

    mapping(address => bool) public poolManagers;
    uint40 public lastStageTimestamp; // Timestamp of the last stage
    uint32 public stageDuration = 1 hours; // default: 1 hour seconds
    uint32 public stageSize = 10; // default: 10 stages
    mapping(uint256 => DoubleEndedQueue.Uint256Deque) liquidityLockedQueue;

    constructor(address initialOwner) Owned(initialOwner) {
        require(initialOwner != address(0), "INVALID_OWNER");
    }

    modifier onlyPoolManager() {
        require(poolManagers[msg.sender], "UNAUTHORIZED");
        _;
    }

    function _getPoolId(PoolId poolId) internal pure returns (uint256 uPoolId) {
        uPoolId = uint256(PoolId.unwrap(poolId));
    }

    // ******************** OWNER CALL ********************
    function addPoolManager(address _manager) external onlyOwner {
        poolManagers[_manager] = true;
    }

    function setStageDuration(uint32 _stageDuration) external onlyOwner {
        stageDuration = _stageDuration;
    }

    function setStageSize(uint32 _stageSize) external onlyOwner {
        stageSize = _stageSize;
    }

    // ********************  INTERNAL CALL ********************

    function _lockLiquidity(uint256 id, uint256 amount) internal {
        if (stageDuration * stageSize == 0) {
            return; // No locking if stageDuration or stageSize is zero
        }
        if (lastStageTimestamp == 0) {
            // Initialize lastStageTimestamp if it's not set
            lastStageTimestamp = uint40(block.timestamp / stageDuration * stageDuration);
        }
        DoubleEndedQueue.Uint256Deque storage queue = liquidityLockedQueue[id];
        uint128 lockAmount = (amount / stageSize).toUint128() + 1; // Ensure at least 1 unit is locked per stage
        uint256 zeroStage = 0;
        if (queue.empty()) {
            for (uint32 i = 0; i < stageSize; i++) {
                queue.pushBack(zeroStage.add(lockAmount));
            }
        } else {
            uint256 queueSize = queue.length();
            for (uint256 i = 0; i < queueSize; i++) {
                uint256 stage = queue.at(i);
                queue.set(i, stage.add(lockAmount));
            }
            for (uint256 i = queueSize; i < stageSize; i++) {
                queue.pushBack(zeroStage.add(lockAmount));
            }
        }
    }

    function _getReleasedLiquidity(uint256 id)
        internal
        view
        returns (uint128 releasedLiquidity, uint128 nextReleasedLiquidity)
    {
        releasedLiquidity = type(uint128).max;
        if (stageDuration * stageSize > 0) {
            DoubleEndedQueue.Uint256Deque storage queue = liquidityLockedQueue[id];
            if (!queue.empty()) {
                uint256 currentStage = queue.front();
                (, releasedLiquidity) = currentStage.decode();
                if (
                    queue.length() > 1 && currentStage.isFree() && block.timestamp >= lastStageTimestamp + stageDuration
                ) {
                    uint256 nextStage = queue.at(1);
                    (, nextReleasedLiquidity) = nextStage.decode();
                }
            }
        }
    }

    // ********************  POOL CALL ********************

    function addLiquidity(address sender, PoolId poolId, uint256 amount) external onlyPoolManager {
        uint256 id = _getPoolId(poolId);
        unchecked {
            _mint(sender, sender, id, amount);
        }
        _lockLiquidity(id, amount);
    }

    function removeLiquidity(address sender, PoolId poolId, uint256 amount)
        external
        onlyPoolManager
        returns (uint256 _totalSupply, uint256 liquidityRemoved)
    {
        uint256 id = _getPoolId(poolId);
        _totalSupply = totalSupply(id);
        if (_totalSupply == 0) {
            revert PoolIsEmpty(); // No liquidity in the pool
        }
        uint256 balance = balanceOf[sender][id];
        liquidityRemoved = Math.min(balance, amount);
        if (stageDuration * stageSize > 0) {
            (uint128 releasedLiquidity, uint128 nextReleasedLiquidity) = _getReleasedLiquidity(id);
            uint256 availableLiquidity = releasedLiquidity + nextReleasedLiquidity;
            if (availableLiquidity < liquidityRemoved) {
                revert LiquidityLocked();
            }
            DoubleEndedQueue.Uint256Deque storage queue = liquidityLockedQueue[id];
            if (!queue.empty()) {
                if (nextReleasedLiquidity > 0) {
                    // If next stage is free, we can release the next stage liquidity
                    uint256 currentStage = queue.popFront(); // Remove the current stage
                    uint256 nextStage = queue.front();
                    (, uint128 currentLiquidity) = currentStage.decode();
                    if (currentLiquidity > liquidityRemoved) {
                        nextStage = nextStage.add((currentLiquidity - liquidityRemoved).toUint128());
                    } else {
                        nextStage = nextStage.sub((liquidityRemoved - currentLiquidity).toUint128());
                    }
                    queue.set(0, nextStage);
                    // Update lastStageTimestamp to the next stage time
                    lastStageTimestamp = uint40(block.timestamp / stageDuration * stageDuration);
                } else {
                    // If next stage is not free, we just reduce the current stage liquidity
                    uint256 currentStage = queue.front();
                    queue.set(0, currentStage.sub(liquidityRemoved.toUint128()));
                }
            }
        }
        unchecked {
            _burn(sender, sender, id, liquidityRemoved);
        }
    }

    // ********************  EXTERNAL CALL ********************
    function getReleasedLiquidity(PoolId poolId) external view returns (uint128 releasedLiquidity) {
        uint256 uPoolId = _getPoolId(poolId);
        uint128 nextReleasedLiquidity;
        (releasedLiquidity, nextReleasedLiquidity) = _getReleasedLiquidity(uPoolId);
        if (nextReleasedLiquidity > 0) {
            releasedLiquidity += nextReleasedLiquidity;
        }
    }

    function getPoolId(PoolId poolId) external pure returns (uint256 uPoolId) {
        uPoolId = _getPoolId(poolId);
    }

    function getTotalSupply(PoolId poolId) external view returns (uint256) {
        uint256 uPoolId = _getPoolId(poolId);
        return totalSupply(uPoolId);
    }

    function getPoolLiquidity(PoolId poolId, address owner) public view returns (uint256 liquidity) {
        uint256 uPoolId = _getPoolId(poolId);
        liquidity = balanceOf[owner][uPoolId];
    }
}
