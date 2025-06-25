// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {DoubleEndedQueue} from "./external/openzeppelin-contracts/DoubleEndedQueue.sol";
// Local
import {ERC6909Liquidity} from "./base/ERC6909Liquidity.sol";
import {TimeLibrary} from "./libraries/TimeLibrary.sol";
import {StageMath} from "./libraries/StageMath.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {PoolStatus, PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";
import {IStatusBase} from "./interfaces/IStatusBase.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";

contract MarginLiquidity is IMarginLiquidity, ERC6909Liquidity, Owned {
    using SafeCast for uint256;
    using UQ112x112 for *;
    using PerLibrary for *;
    using TimeLibrary for uint32;
    using StageMath for uint256;
    using StageMath for uint256[];
    using PoolStatusLibrary for PoolStatus;
    using DoubleEndedQueue for DoubleEndedQueue.Uint256Deque;

    error LiquidityLocked();

    mapping(address => bool) public interestOperator;
    mapping(PoolId => int256) public interestStore0;
    mapping(PoolId => int256) public interestStore1;
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

    modifier onlyInterestOperator() {
        require(interestOperator[msg.sender], "UNAUTHORIZED");
        _;
    }

    function _getPoolId(PoolId poolId) internal pure returns (uint256 uPoolId) {
        uPoolId = uint256(PoolId.unwrap(poolId));
    }

    function _updateRatio(address pairPoolManager, uint256 id, int256 liquidity) internal {
        if (liquidity != 0) {
            uint256 totalLiquidity = balanceOriginal[pairPoolManager][id];
            if (liquidity > 0) {
                accruesRatioX112Of[id] = accruesRatioX112Of[id].growRatioX112(uint256(liquidity), totalLiquidity);
            } else {
                accruesRatioX112Of[id] = accruesRatioX112Of[id].reduceRatioX112(uint256(-liquidity), totalLiquidity);
            }
        }
    }

    function _addInterests(
        address pairPoolManager,
        PoolId poolId,
        uint256 _reserve0,
        uint256 _reserve1,
        uint256 interest0,
        uint256 interest1
    ) internal returns (uint256 liquidity) {
        int256 store0 = interestStore0[poolId];
        if (store0 >= 0) {
            interest0 += uint256(store0);
            interestStore0[poolId] = 0;
        } else {
            if (interest0 > uint256(-store0)) {
                interest0 -= uint256(-store0);
                interestStore0[poolId] = 0;
            } else {
                interest0 = 0;
                interestStore0[poolId] += int256(interest0);
            }
        }
        int256 store1 = interestStore1[poolId];
        if (store1 >= 0) {
            interest1 += uint256(store1);
            interestStore1[poolId] = 0;
        } else {
            if (interest1 > uint256(-store1)) {
                interest1 -= uint256(-store1);
                interestStore1[poolId] = 0;
            } else {
                interest1 = 0;
                interestStore1[poolId] += int256(interest1);
            }
        }
        uint256 rootKLast = Math.sqrt(_reserve0 * _reserve1);
        uint256 rootK = Math.sqrt((_reserve0 + interest0) * (_reserve1 + interest1));
        if (rootK > rootKLast) {
            uint256 uPoolId = _getPoolId(poolId);
            uint256 _totalSupply = balanceOf(pairPoolManager, uPoolId);
            uint256 numerator = _totalSupply * (rootK - rootKLast);
            uint256 denominator = rootK + rootKLast;
            liquidity = numerator / denominator;
            if (liquidity > 0) {
                _updateRatio(pairPoolManager, uPoolId, int256(liquidity));
            } else {
                interestStore0[poolId] += int256(interest0);
                interestStore1[poolId] += int256(interest1);
            }
        }
    }

    function _deductInterests(
        address pairPoolManager,
        PoolId poolId,
        uint256 _reserve0,
        uint256 _reserve1,
        uint256 interest0,
        uint256 interest1
    ) internal returns (uint256 liquidity) {
        int256 store0 = interestStore0[poolId];
        if (store0 <= 0) {
            interest0 += uint256(-store0);
            interestStore0[poolId] = 0;
        } else {
            if (interest0 > uint256(store0)) {
                interest0 -= uint256(store0);
                interestStore0[poolId] = 0;
            } else {
                interest0 = 0;
                interestStore0[poolId] -= int256(interest0);
            }
        }
        int256 store1 = interestStore1[poolId];
        if (store1 <= 0) {
            interest1 += uint256(-store1);
            interestStore1[poolId] = 0;
        } else {
            if (interest1 > uint256(store1)) {
                interest1 -= uint256(store1);
                interestStore1[poolId] = 0;
            } else {
                interest1 = 0;
                interestStore1[poolId] -= int256(interest1);
            }
        }
        uint256 rootKLast = Math.sqrt(_reserve0 * _reserve1);
        uint256 rootK = Math.sqrt((_reserve0 - interest0) * (_reserve1 - interest1));
        if (rootKLast > rootK) {
            uint256 uPoolId = _getPoolId(poolId);
            uint256 _totalSupply = balanceOf(pairPoolManager, uPoolId);
            uint256 numerator = _totalSupply * (rootKLast - rootK);
            uint256 denominator = rootK + rootKLast;
            liquidity = numerator / denominator;
            if (liquidity > 0) {
                _updateRatio(pairPoolManager, uPoolId, -int256(liquidity));
            } else {
                interestStore0[poolId] -= int256(interest0);
                interestStore1[poolId] -= int256(interest1);
            }
        }
    }

    // ******************** OWNER CALL ********************
    function addPoolManager(address _manager) external onlyOwner {
        poolManagers[_manager] = true;
        address statusManager = address(IPairPoolManager(_manager).statusManager());
        require(statusManager != address(0), "STATUS_MANAGER_ERROR");
        interestOperator[statusManager] = true;
    }

    function setStageDuration(uint32 _stageDuration) external onlyOwner {
        stageDuration = _stageDuration;
    }

    function setStageSize(uint32 _stageSize) external onlyOwner {
        stageSize = _stageSize;
    }

    // ********************  POOL CALL ********************

    function addInterests(PoolId poolId, uint256 _reserve0, uint256 _reserve1, uint256 interest0, uint256 interest1)
        external
        onlyInterestOperator
        returns (uint256 liquidity)
    {
        address pairPoolManager = IStatusBase(msg.sender).pairPoolManager();
        liquidity = _addInterests(pairPoolManager, poolId, _reserve0, _reserve1, interest0, interest1);
    }

    function changeLiquidity(PoolId poolId, uint256 _reserve0, uint256 _reserve1, int256 interest0, int256 interest1)
        external
        onlyPoolManager
        returns (uint256 liquidity)
    {
        address pairPoolManager = msg.sender;
        if (interest0 >= 0 && interest1 >= 0) {
            liquidity =
                _addInterests(pairPoolManager, poolId, _reserve0, _reserve1, uint256(interest0), uint256(interest1));
        }
        if (interest0 <= 0 && interest1 <= 0) {
            liquidity = _deductInterests(
                pairPoolManager, poolId, _reserve0, _reserve1, uint256(-interest0), uint256(-interest1)
            );
        }
    }

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

    function addLiquidity(address sender, uint256 id, uint256 amount) external onlyPoolManager {
        address pairPoolManager = msg.sender;
        unchecked {
            _mint(sender, pairPoolManager, id, amount);
            _mint(sender, sender, id, amount);
        }
        _lockLiquidity(id, amount);
    }

    function getLockedLiquidity(PoolId poolId) external view returns (uint256 lockedLiquidity) {
        uint256 uPoolId = _getPoolId(poolId);
        lockedLiquidity = _getLockedLiquidity(uPoolId);
    }

    function _getLockedLiquidity(uint256 id) internal view returns (uint256 lockedLiquidity) {
        if (stageDuration * stageSize == 0) {
            return lockedLiquidity; // No locking if stageDuration or stageSize is zero
        }
        DoubleEndedQueue.Uint256Deque storage queue = liquidityLockedQueue[id];
        if (!queue.empty()) {
            uint256 currentTimestamp = block.timestamp;
            uint256 oldestTimestamp = currentTimestamp - uint256(stageDuration) * stageSize;
            uint256 lowLimit = currentTimestamp - MAX_LOCK_SECONDS; // Maximum lock time limit
            uint256 stageStep = 0;
            for (uint256 i = queue.length(); i > 0; i--) {
                uint256 stage = queue.at(i - 1);
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

    function removeLiquidity(address sender, uint256 id, uint256 amount) external onlyPoolManager returns (uint256) {
        address pairPoolManager = msg.sender;
        uint256 balance = balanceOf(sender, id);
        amount = Math.min(balance, amount);
        uint256 totalSupply = balanceOf(pairPoolManager, id);
        uint256 lockedLiquidity = _getLockedLiquidity(id);
        if (lockedLiquidity > totalSupply) {
            revert LiquidityLocked();
        } else {
            uint256 availableLiquidity = totalSupply - lockedLiquidity;
            if (availableLiquidity < amount) {
                revert LiquidityLocked();
            }
        }
        unchecked {
            _burn(sender, pairPoolManager, id, amount);
            _burn(sender, sender, id, amount);
        }
        return amount;
    }

    function getTotalSupply(uint256 uPoolId) external view onlyPoolManager returns (uint256 totalSupply) {
        (totalSupply) = balanceOf(msg.sender, uPoolId);
    }

    // ********************  EXTERNAL CALL ********************
    function getPoolId(PoolId poolId) external pure returns (uint256 uPoolId) {
        uPoolId = _getPoolId(poolId);
    }

    ///@inheritdoc IMarginLiquidity
    function getPoolTotalSupply(address poolManager, PoolId poolId) external view returns (uint256 totalSupply) {
        uint256 uPoolId = _getPoolId(poolId);
        (totalSupply) = balanceOf(poolManager, uPoolId);
    }

    function getPoolLiquidity(PoolId poolId, address owner) public view returns (uint256 liquidity) {
        uint256 uPoolId = _getPoolId(poolId);
        liquidity = balanceOf(owner, uPoolId);
    }
}
