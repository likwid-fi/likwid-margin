// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {DoubleEndedQueue} from "./external/openzeppelin-contracts/DoubleEndedQueue.sol";
// Local
import {ERC6909Liquidity} from "./base/ERC6909Liquidity.sol";
import {StageMath} from "./libraries/StageMath.sol";

import {PoolStatus, PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";
import {IStatusBase} from "./interfaces/IStatusBase.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";

contract MarginLiquidity is IMarginLiquidity, ERC6909Liquidity, Owned {
    using StageMath for uint256;
    using PoolStatusLibrary for PoolStatus;
    using DoubleEndedQueue for DoubleEndedQueue.Uint256Deque;

    error LiquidityLocked();
    error PoolIsEmpty();

    mapping(address => bool) public poolManagers;
    uint256 constant MAX_LOCK_SECONDS = 10 days;
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
        DoubleEndedQueue.Uint256Deque storage queue = liquidityLockedQueue[id];
        if (queue.empty()) {
            uint40 lastTimestamp = uint40((block.timestamp / stageDuration + 1) * stageDuration);
            uint256 lastStage = StageMath.encode(lastTimestamp, amount);
            queue.pushBack(lastStage);
        } else {
            uint256 lastStage = queue.back();
            (uint40 lastTimestamp, uint256 lastLiquidity) = lastStage.decode();
            uint40 currentTimestamp = uint40(block.timestamp);
            if (lastTimestamp > currentTimestamp) {
                lastStage = StageMath.encode(lastTimestamp, lastLiquidity + amount);
                queue.set(queue.length() - 1, lastStage);
            } else {
                lastTimestamp = uint40((block.timestamp / stageDuration + 1) * stageDuration);
                lastStage = StageMath.encode(lastTimestamp, amount);
                queue.pushBack(lastStage);
            }
        }
    }

    function _getLockedLiquidity(uint256 id) internal view returns (uint256 lockedLiquidity, uint256 expiredSize) {
        if (stageDuration * stageSize == 0) {
            return (lockedLiquidity, expiredSize); // No locking if stageDuration or stageSize is zero
        }
        DoubleEndedQueue.Uint256Deque storage queue = liquidityLockedQueue[id];
        if (!queue.empty()) {
            uint256 currentTimestamp = block.timestamp;
            uint256 oldestTimestamp = currentTimestamp - uint256(stageDuration) * stageSize;
            uint256 lowLimit = currentTimestamp - MAX_LOCK_SECONDS; // Maximum lock time limit
            uint256 stageStep = 0;
            for (expiredSize = queue.length(); expiredSize > 0; expiredSize--) {
                uint256 stage = queue.at(expiredSize - 1);
                (uint40 timestamp, uint256 liquidity) = stage.decode();
                if (timestamp < oldestTimestamp || timestamp < lowLimit) {
                    break; // Skip stages that are too old
                }
                for (; stageStep < stageSize; stageStep++) {
                    uint256 lowTime = (currentTimestamp / stageDuration - stageStep) * stageDuration;
                    if (timestamp > lowTime) {
                        lockedLiquidity += Math.mulDiv(liquidity, stageSize - stageStep, stageSize);
                        break;
                    }
                }
            }
        }
    }

    function _clearExpiredQueue(uint256 id, uint256 expiredSize) internal {
        DoubleEndedQueue.Uint256Deque storage queue = liquidityLockedQueue[id];
        if (queue.length() > expiredSize) {
            for (; expiredSize > 0; expiredSize--) {
                queue.popFront();
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
        (uint256 lockedLiquidity, uint256 expiredSize) = _getLockedLiquidity(id);
        if (lockedLiquidity > _totalSupply) {
            revert LiquidityLocked();
        } else {
            uint256 availableLiquidity = _totalSupply - lockedLiquidity;
            if (availableLiquidity < liquidityRemoved) {
                revert LiquidityLocked();
            }
        }
        unchecked {
            _burn(sender, sender, id, liquidityRemoved);
        }
        _clearExpiredQueue(id, expiredSize);
    }

    // ********************  EXTERNAL CALL ********************
    function getLockedLiquidity(PoolId poolId) external view returns (uint256 lockedLiquidity) {
        uint256 uPoolId = _getPoolId(poolId);
        (lockedLiquidity,) = _getLockedLiquidity(uPoolId);
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
