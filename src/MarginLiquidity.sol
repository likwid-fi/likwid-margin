// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
// Local
import {ERC6909Liquidity} from "./base/ERC6909Liquidity.sol";
import {LiquidityLevel} from "./libraries/LiquidityLevel.sol";
import {TimeLibrary} from "./libraries/TimeLibrary.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {PoolStatus, PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";
import {IStatusBase} from "./interfaces/IStatusBase.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";

contract MarginLiquidity is IMarginLiquidity, ERC6909Liquidity, Owned {
    using SafeCast for uint256;
    using LiquidityLevel for *;
    using UQ112x112 for *;
    using PerLibrary for *;
    using TimeLibrary for uint32;
    using PoolStatusLibrary for PoolStatus;

    uint24 private maxSliding = 5000; // 0.5%
    mapping(address => bool) public interestOperator;
    mapping(PoolId => int256) public interestStore0;
    mapping(PoolId => int256) public interestStore1;

    mapping(address => mapping(uint256 => uint256)) public increaseStore;

    constructor(address initialOwner) Owned(initialOwner) {}

    modifier onlyPoolManager() {
        require(poolManagers[msg.sender], "UNAUTHORIZED");
        _;
    }

    modifier onlyInterestOperator() {
        require(interestOperator[msg.sender], "UNAUTHORIZED");
        _;
    }

    function getMaxSliding() external view returns (uint24) {
        return maxSliding;
    }

    function _getPoolId(PoolId poolId) internal pure returns (uint256 uPoolId) {
        uPoolId = uint256(PoolId.unwrap(poolId)).getPoolId();
    }

    function _getPoolSupplies(address poolManager, uint256 uPoolId)
        internal
        view
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1)
    {
        uPoolId = uPoolId & LiquidityLevel.LP_FLAG;
        totalSupply = balanceOf(poolManager, uPoolId);
        uint256 lPoolId = LiquidityLevel.RETAIN_BOTH.getLevelId(uPoolId);
        retainSupply0 = retainSupply1 = balanceOf(poolManager, lPoolId);
        lPoolId = LiquidityLevel.BORROW_TOKEN1.getLevelId(uPoolId);
        retainSupply0 += balanceOf(poolManager, lPoolId);
        lPoolId = LiquidityLevel.BORROW_TOKEN0.getLevelId(uPoolId);
        retainSupply1 += balanceOf(poolManager, lPoolId);
    }

    function _updateLevelRatio(
        address pairPoolManager,
        uint256 id,
        uint256 liquidity0,
        uint256 liquidity1,
        bool addFlag
    ) internal {
        uint256 level4Id = LiquidityLevel.BORROW_BOTH.getLevelId(id);
        uint256 total4Liquidity = balanceOriginal[pairPoolManager][level4Id];
        uint256 level4Liquidity;
        if (liquidity0 > 0) {
            uint256 level2Id = LiquidityLevel.BORROW_TOKEN0.getLevelId(id);
            uint256 total2Liquidity = balanceOriginal[pairPoolManager][level2Id];
            if (total2Liquidity > 0) {
                uint256 level2Liquidity = Math.mulDiv(liquidity0, total2Liquidity, total2Liquidity + total4Liquidity);
                level4Liquidity += liquidity0 - level2Liquidity;
                if (addFlag) {
                    accruesRatioX112Of[level2Id] =
                        accruesRatioX112Of[level2Id].growRatioX112(level2Liquidity, total2Liquidity);
                } else {
                    accruesRatioX112Of[level2Id] =
                        accruesRatioX112Of[level2Id].reduceRatioX112(level2Liquidity, total2Liquidity);
                }
            } else {
                level4Liquidity += liquidity0;
            }
        }
        if (liquidity1 > 0) {
            uint256 level3Id = LiquidityLevel.BORROW_TOKEN1.getLevelId(id);
            uint256 total3Liquidity = balanceOriginal[pairPoolManager][level3Id];
            if (total3Liquidity > 0) {
                uint256 level3Liquidity = Math.mulDiv(liquidity1, total3Liquidity, total3Liquidity + total4Liquidity);
                level4Liquidity += liquidity1 - level3Liquidity;
                if (addFlag) {
                    accruesRatioX112Of[level3Id] =
                        accruesRatioX112Of[level3Id].growRatioX112(level3Liquidity, total3Liquidity);
                } else {
                    accruesRatioX112Of[level3Id] =
                        accruesRatioX112Of[level3Id].reduceRatioX112(level3Liquidity, total3Liquidity);
                }
            } else {
                level4Liquidity += liquidity1;
            }
        }
        if (total4Liquidity > 0) {
            if (addFlag) {
                accruesRatioX112Of[level4Id] =
                    accruesRatioX112Of[level4Id].growRatioX112(level4Liquidity, total4Liquidity);
            } else {
                accruesRatioX112Of[level4Id] =
                    accruesRatioX112Of[level4Id].reduceRatioX112(level4Liquidity, total4Liquidity);
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
                uint256 _total = balanceOriginal[pairPoolManager][uPoolId];
                uint256 liquidity0;
                uint256 liquidity1;
                if (interest0 == 0) {
                    liquidity1 = liquidity;
                } else if (interest1 == 0) {
                    liquidity0 = liquidity;
                } else {
                    denominator = interest0 + Math.mulDiv(interest1, _reserve0, _reserve1);
                    liquidity0 = Math.mulDiv(liquidity, interest0, denominator);
                    liquidity1 = liquidity - liquidity0;
                    if (liquidity0 == 0 || liquidity1 == 0) {
                        interestStore0[poolId] += int256(interest0);
                        interestStore1[poolId] += int256(interest1);
                        return liquidity;
                    }
                }
                accruesRatioX112Of[uPoolId] = accruesRatioX112Of[uPoolId].growRatioX112(liquidity, _total);
                _updateLevelRatio(pairPoolManager, uPoolId, liquidity0, liquidity1, true);
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
                uint256 _total = balanceOriginal[pairPoolManager][uPoolId];
                uint256 liquidity0;
                uint256 liquidity1;
                if (interest0 == 0) {
                    liquidity1 = liquidity;
                } else if (interest1 == 0) {
                    liquidity0 = liquidity;
                } else {
                    denominator = interest0 + Math.mulDiv(interest1, _reserve0, _reserve1);
                    liquidity0 = Math.mulDiv(liquidity, interest0, denominator);
                    liquidity1 = liquidity - liquidity0;
                    if (liquidity0 == 0 || liquidity1 == 0) {
                        interestStore0[poolId] -= int256(interest0);
                        interestStore1[poolId] -= int256(interest1);
                        return liquidity;
                    }
                }
                accruesRatioX112Of[uPoolId] = accruesRatioX112Of[uPoolId].reduceRatioX112(liquidity, _total);
                _updateLevelRatio(pairPoolManager, uPoolId, liquidity0, liquidity1, false);
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

    function setMaxSliding(uint24 _maxSliding) external onlyOwner {
        maxSliding = _maxSliding;
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

    function addLiquidity(address caller, address receiver, uint256 id, uint8 level, uint256 amount)
        external
        onlyPoolManager
    {
        address pairPoolManager = msg.sender;
        if (pairPoolManager == receiver) revert ErrorReceiver();
        uint256 levelId = level.getLevelId(id);
        uint256 uPoolId = id.getPoolId();
        uint256 increaseResult = increaseStore[receiver][levelId].increaseTimeStampStore(amount);
        (uint32 t, uint224 v) = increaseResult.decodeTimeStampStore();
        uint256 total = balanceOf(pairPoolManager, uPoolId);
        if (v > total / 100) {
            datetimeStore[receiver][levelId] = t;
        }
        unchecked {
            _mint(caller, pairPoolManager, uPoolId, amount);
            _mint(caller, pairPoolManager, levelId, amount);
            _mint(caller, receiver, levelId, amount);
        }
        increaseStore[receiver][levelId] = increaseResult;
    }

    function removeLiquidity(address sender, uint256 id, uint8 level, uint256 amount)
        external
        onlyPoolManager
        returns (uint256)
    {
        uint256 levelId = level.getLevelId(id);
        uint256 uPoolId = id.getPoolId();
        address pairPoolManager = msg.sender;
        uint256 balance = balanceOf(sender, levelId);
        amount = Math.min(balance, amount);
        unchecked {
            _burn(sender, pairPoolManager, uPoolId, amount);
            _burn(sender, pairPoolManager, levelId, amount);
            _burn(sender, sender, levelId, amount);
        }
        return amount;
    }

    function getSupplies(uint256 uPoolId)
        external
        view
        onlyPoolManager
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1)
    {
        (totalSupply, retainSupply0, retainSupply1) = _getPoolSupplies(msg.sender, uPoolId);
    }

    // ********************  EXTERNAL CALL ********************
    function getPoolId(PoolId poolId) external pure returns (uint256 uPoolId) {
        uPoolId = _getPoolId(poolId);
    }

    ///@inheritdoc IMarginLiquidity
    function getPoolSupplies(address poolManager, PoolId poolId)
        external
        view
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1)
    {
        uint256 uPoolId = _getPoolId(poolId);
        (totalSupply, retainSupply0, retainSupply1) = _getPoolSupplies(poolManager, uPoolId);
    }

    function getPoolLiquidity(PoolId poolId, address owner, uint8 level) public view returns (uint256 liquidity) {
        level.validate();
        uint256 uPoolId = uint256(PoolId.unwrap(poolId));
        uint256 levelId = level.getLevelId(uPoolId);
        liquidity = balanceOf(owner, levelId);
    }

    function getPoolLiquidities(PoolId poolId, address owner) external view returns (uint256[4] memory liquidities) {
        for (uint256 i = 0; i < 4; i++) {
            uint8 level = uint8(1 + i);
            liquidities[i] = getPoolLiquidity(poolId, owner, level);
        }
    }

    ///@inheritdoc IMarginLiquidity
    function getInterestReserves(address pairPoolManager, PoolId poolId, PoolStatus memory status)
        public
        view
        returns (uint256 reserve0, uint256 reserve1)
    {
        uint256 uPoolId = _getPoolId(poolId);
        (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1) = _getPoolSupplies(pairPoolManager, uPoolId);
        if (totalSupply > 0) {
            reserve0 = Math.mulDiv(totalSupply - retainSupply0, status.reserve0(), totalSupply);
            reserve1 = Math.mulDiv(totalSupply - retainSupply1, status.reserve1(), totalSupply);
        }
    }

    function getInterestReserves(address pairPoolManager, PoolId poolId)
        external
        view
        returns (uint256 reserve0, uint256 reserve1)
    {
        PoolStatus memory status = IPairPoolManager(pairPoolManager).getStatus(poolId);
        (reserve0, reserve1) = getInterestReserves(pairPoolManager, poolId, status);
    }

    function getFlowReserves(address pairPoolManager, PoolId poolId, PoolStatus memory status)
        external
        view
        returns (uint256 reserve0, uint256 reserve1)
    {
        uint256 uPoolId = _getPoolId(poolId);
        (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1) = _getPoolSupplies(pairPoolManager, uPoolId);
        if (totalSupply > 0) {
            uint256 maxReserve0 = status.realReserve0;
            uint256 maxReserve1 = status.realReserve1;
            uint256 retainAmount0 = Math.mulDiv(retainSupply0, status.reserve0(), totalSupply);
            uint256 retainAmount1 = Math.mulDiv(retainSupply1, status.reserve1(), totalSupply);
            if (maxReserve0 > retainAmount0) {
                reserve0 = maxReserve0 - retainAmount0;
            }
            if (maxReserve1 > retainAmount1) {
                reserve1 = maxReserve1 - retainAmount1;
            }
        }
    }

    function getMarginReserves(address pairPoolManager, PoolId poolId, PoolStatus memory status)
        public
        view
        returns (
            uint256 marginReserve0,
            uint256 marginReserve1,
            uint256 incrementMaxMirror0,
            uint256 incrementMaxMirror1
        )
    {
        uint256 uPoolId = _getPoolId(poolId);
        (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1) = _getPoolSupplies(pairPoolManager, uPoolId);
        if (totalSupply > 0) {
            marginReserve0 = Math.mulDiv(totalSupply - retainSupply1, status.reserve0(), totalSupply);
            marginReserve1 = Math.mulDiv(totalSupply - retainSupply0, status.reserve1(), totalSupply);
            marginReserve0 = Math.min(marginReserve0, status.realReserve0);
            marginReserve1 = Math.min(marginReserve1, status.realReserve1);

            if (retainSupply0 > 0) {
                uint256 maxMirror0 = Math.mulDiv(totalSupply - retainSupply0, status.reserve0(), totalSupply);
                if (maxMirror0 > status.mirrorReserve0) {
                    incrementMaxMirror0 = Math.mulDiv(maxMirror0 - status.mirrorReserve0, totalSupply, retainSupply0);
                }
            } else {
                incrementMaxMirror0 = type(uint112).max / 2;
            }
            if (retainSupply1 > 0) {
                uint256 maxMirror1 = Math.mulDiv(totalSupply - retainSupply1, status.reserve1(), totalSupply);
                if (maxMirror1 > status.mirrorReserve1) {
                    incrementMaxMirror1 = Math.mulDiv(maxMirror1 - status.mirrorReserve1, totalSupply, retainSupply1);
                }
            } else {
                incrementMaxMirror1 = type(uint112).max / 2;
            }
        }
    }

    function getMarginReserves(address pairPoolManager, PoolId poolId)
        external
        view
        returns (
            uint256 marginReserve0,
            uint256 marginReserve1,
            uint256 incrementMaxMirror0,
            uint256 incrementMaxMirror1
        )
    {
        PoolStatus memory status = IPairPoolManager(pairPoolManager).getStatus(poolId);
        (marginReserve0, marginReserve1, incrementMaxMirror0, incrementMaxMirror1) =
            getMarginReserves(pairPoolManager, poolId, status);
    }
}
