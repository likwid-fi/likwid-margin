// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
// Local
import {ERC6909Accrues} from "./base/ERC6909Accrues.sol";
import {LiquidityLevel} from "./libraries/LiquidityLevel.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {PoolStatus, PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";
import {IStatusBase} from "./interfaces/IStatusBase.sol";
import {IPoolBase} from "./interfaces/IPoolBase.sol";

contract MarginLiquidity is IMarginLiquidity, ERC6909Accrues, Owned {
    using SafeCast for uint256;
    using LiquidityLevel for *;
    using UQ112x112 for *;
    using PerLibrary for *;
    using PoolStatusLibrary for PoolStatus;

    error NotAllowed();

    mapping(address => bool) public poolManagers;
    uint24 private maxSliding = 5000; // 0.5%
    uint256 public level2InterestRatioX112 = UQ112x112.Q112;
    uint256 public level3InterestRatioX112 = UQ112x112.Q112;
    uint256 public level4InterestRatioX112 = UQ112x112.Q112;

    constructor(address initialOwner) Owned(initialOwner) {}

    modifier onlyPoolManager() {
        require(poolManagers[msg.sender], "UNAUTHORIZED");
        _;
    }

    modifier onlyStatus() {
        require(poolManagers[IStatusBase(msg.sender).pairPoolManager()], "UNAUTHORIZED");
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
        uint256 lPoolId = LiquidityLevel.NO_MARGIN.getLevelId(uPoolId);
        retainSupply0 = retainSupply1 = balanceOf(poolManager, lPoolId);
        lPoolId = LiquidityLevel.ZERO_MARGIN.getLevelId(uPoolId);
        retainSupply0 += balanceOf(poolManager, lPoolId);
        lPoolId = LiquidityLevel.ONE_MARGIN.getLevelId(uPoolId);
        retainSupply1 += balanceOf(poolManager, lPoolId);
    }

    function _updateLevelRatio(
        address pairPoolManager,
        uint256 id,
        uint256 liquidity0,
        uint256 liquidity1,
        bool addFlag
    ) internal {
        uint256 level4Id = LiquidityLevel.BOTH_MARGIN.getLevelId(id);
        uint256 total4Liquidity = balanceOf(pairPoolManager, level4Id);
        uint256 level4Liquidity;
        if (liquidity0 > 0) {
            uint256 level2Id = LiquidityLevel.ONE_MARGIN.getLevelId(id);
            uint256 total2Liquidity = balanceOf(pairPoolManager, level2Id);
            if (total2Liquidity > 0) {
                uint256 level2Liquidity = Math.mulDiv(liquidity0, total2Liquidity, total2Liquidity + total4Liquidity);
                level4Liquidity += liquidity0 - level2Liquidity;
                if (addFlag) {
                    level2InterestRatioX112 = level2InterestRatioX112.growRatioX112(level2Liquidity, total2Liquidity);
                    _mint(pairPoolManager, level2Id, level2Liquidity);
                } else {
                    level2InterestRatioX112 = level2InterestRatioX112.reduceRatioX112(level2Liquidity, total2Liquidity);
                    _burn(pairPoolManager, level2Id, level2Liquidity);
                }
            } else {
                level4Liquidity += liquidity0;
            }
        }
        if (liquidity1 > 0) {
            uint256 level3Id = LiquidityLevel.ZERO_MARGIN.getLevelId(id);
            uint256 total3Liquidity = balanceOf(pairPoolManager, level3Id);
            if (total3Liquidity > 0) {
                uint256 level3Liquidity = Math.mulDiv(liquidity1, total3Liquidity, total3Liquidity + total4Liquidity);
                level4Liquidity += liquidity1 - level3Liquidity;
                if (addFlag) {
                    level3InterestRatioX112 = level3InterestRatioX112.growRatioX112(level3Liquidity, total3Liquidity);
                    _mint(pairPoolManager, level3Id, level3Liquidity);
                } else {
                    level3InterestRatioX112 = level3InterestRatioX112.reduceRatioX112(level3Liquidity, total3Liquidity);
                    _burn(pairPoolManager, level3Id, level3Liquidity);
                }
            } else {
                level4Liquidity += liquidity1;
            }
        }
        if (addFlag) {
            level4InterestRatioX112 = level4InterestRatioX112.growRatioX112(level4Liquidity, total4Liquidity);
            _mint(pairPoolManager, level4Id, level4Liquidity);
        } else {
            level4InterestRatioX112 = level4InterestRatioX112.reduceRatioX112(level4Liquidity, total4Liquidity);
            _burn(pairPoolManager, level4Id, level4Liquidity);
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
        uint256 rootKLast = Math.sqrt(_reserve0 * _reserve1);
        uint256 rootK = Math.sqrt((_reserve0 + interest0) * (_reserve1 + interest1));
        if (rootK > rootKLast) {
            uint256 uPoolId = _getPoolId(poolId);
            uint256 _totalSupply = balanceOf(pairPoolManager, uPoolId);
            uint256 numerator = _totalSupply * (rootK - rootKLast);
            uint256 denominator = rootK + rootKLast;
            liquidity = numerator / denominator;
            if (liquidity > 0) {
                _mint(pairPoolManager, uPoolId, liquidity);
                denominator = interest0 + Math.mulDiv(interest1, _reserve0, _reserve1);
                uint256 liquidity0 = Math.mulDiv(liquidity, interest0, denominator);
                uint256 liquidity1 = liquidity - liquidity0;
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
        uint256 rootKLast = Math.sqrt(_reserve0 * _reserve1);
        uint256 rootK = Math.sqrt((_reserve0 - interest0) * (_reserve1 - interest1));
        if (rootKLast > rootK) {
            uint256 uPoolId = _getPoolId(poolId);
            uint256 _totalSupply = balanceOf(pairPoolManager, uPoolId);
            uint256 numerator = _totalSupply * (rootKLast - rootK);
            uint256 denominator = rootK + rootKLast;
            liquidity = numerator / denominator;
            if (liquidity > 0) {
                _burn(pairPoolManager, uPoolId, liquidity);
                denominator = interest0 + Math.mulDiv(interest1, _reserve0, _reserve1);
                uint256 liquidity0 = Math.mulDiv(liquidity, interest0, denominator);
                uint256 liquidity1 = liquidity - liquidity0;
                _updateLevelRatio(pairPoolManager, uPoolId, liquidity0, liquidity1, false);
            }
        }
    }

    // ******************** OWNER CALL ********************
    function addPoolManager(address _manager) external onlyOwner {
        poolManagers[_manager] = true;
    }

    function setMaxSliding(uint24 _maxSliding) external onlyOwner {
        maxSliding = _maxSliding;
    }

    // ********************  POOL CALL ********************

    function addInterests(PoolId poolId, uint256 _reserve0, uint256 _reserve1, uint256 interest0, uint256 interest1)
        external
        onlyStatus
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
        if (interest0 >= 0 && interest1 >= 0) {
            liquidity = _addInterests(msg.sender, poolId, _reserve0, _reserve1, uint256(interest0), uint256(interest1));
        }
        if (interest0 <= 0 && interest1 <= 0) {
            liquidity =
                _deductInterests(msg.sender, poolId, _reserve0, _reserve1, uint256(-interest0), uint256(-interest1));
        }
    }

    function addLiquidity(address receiver, uint256 id, uint8 level, uint256 amount)
        external
        onlyPoolManager
        returns (uint256 liquidity)
    {
        uint256 uPoolId = id.getPoolId();
        uint256 levelId = level.getLevelId(id);
        address pool = msg.sender;
        liquidity = amount;
        if (level == LiquidityLevel.ONE_MARGIN) {
            liquidity = amount.divRatioX112(level2InterestRatioX112);
        } else if (level == LiquidityLevel.ZERO_MARGIN) {
            liquidity = amount.divRatioX112(level3InterestRatioX112);
        } else if (level == LiquidityLevel.BOTH_MARGIN) {
            liquidity = amount.divRatioX112(level4InterestRatioX112);
        }

        unchecked {
            _mint(pool, uPoolId, amount);
            _mint(pool, levelId, amount);
            _mint(receiver, levelId, liquidity);
        }
    }

    function removeLiquidity(address sender, uint256 id, uint8 level, uint256 amount, uint32 statusLastUpdated)
        external
        onlyPoolManager
        returns (uint256 liquidity)
    {
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        if (statusLastUpdated == blockTS) {
            revert NotAllowed();
        }
        uint256 uPoolId = id.getPoolId();
        uint256 levelId = level.getLevelId(id);
        address pool = msg.sender;
        liquidity = amount;
        if (level == LiquidityLevel.ONE_MARGIN) {
            liquidity = amount.divRatioX112(level2InterestRatioX112);
        } else if (level == LiquidityLevel.ZERO_MARGIN) {
            liquidity = amount.divRatioX112(level3InterestRatioX112);
        } else if (level == LiquidityLevel.BOTH_MARGIN) {
            liquidity = amount.divRatioX112(level4InterestRatioX112);
        }
        unchecked {
            _burn(pool, uPoolId, amount);
            _burn(pool, levelId, amount);
            _burn(sender, levelId, liquidity);
        }
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
    function getPoolSupplies(address pool, PoolId poolId)
        external
        view
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1)
    {
        uint256 uPoolId = _getPoolId(poolId);
        (totalSupply, retainSupply0, retainSupply1) = _getPoolSupplies(pool, uPoolId);
    }

    function getPoolLiquidity(PoolId poolId, address owner, uint8 level) public view returns (uint256 liquidity) {
        level.validate();
        uint256 uPoolId = uint256(PoolId.unwrap(poolId));
        uint256 levelId = level.getLevelId(uPoolId);
        uint256 amount = balanceOf(owner, levelId);
        if (level == LiquidityLevel.ONE_MARGIN) {
            liquidity = amount.mulRatioX112(level2InterestRatioX112);
        } else if (level == LiquidityLevel.ZERO_MARGIN) {
            liquidity = amount.mulRatioX112(level3InterestRatioX112);
        } else if (level == LiquidityLevel.BOTH_MARGIN) {
            liquidity = amount.mulRatioX112(level4InterestRatioX112);
        } else {
            liquidity = amount;
        }
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
        PoolStatus memory status = IPoolBase(pairPoolManager).getStatus(poolId);
        (reserve0, reserve1) = getInterestReserves(pairPoolManager, poolId, status);
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
            uint256 canMirrorReserve0 = Math.mulDiv(totalSupply - retainSupply0, status.reserve0(), totalSupply);
            uint256 canMirrorReserve1 = Math.mulDiv(totalSupply - retainSupply1, status.reserve1(), totalSupply);
            if (canMirrorReserve0 > status.mirrorReserve0) {
                if (retainSupply0 > 0) {
                    incrementMaxMirror0 =
                        Math.mulDiv(canMirrorReserve0 - status.mirrorReserve0, totalSupply, retainSupply0);
                } else {
                    incrementMaxMirror0 = type(uint112).max;
                }
            }
            if (canMirrorReserve1 > status.mirrorReserve1) {
                if (retainSupply1 > 0) {
                    incrementMaxMirror1 =
                        Math.mulDiv(canMirrorReserve1 - status.mirrorReserve1, totalSupply, retainSupply1);
                } else {
                    incrementMaxMirror1 = type(uint112).max;
                }
            }

            marginReserve0 = Math.min(marginReserve0, status.realReserve0);
            marginReserve1 = Math.min(marginReserve1, status.realReserve1);
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
        PoolStatus memory status = IPoolBase(pairPoolManager).getStatus(poolId);
        (marginReserve0, marginReserve1, incrementMaxMirror0, incrementMaxMirror1) =
            getMarginReserves(pairPoolManager, poolId, status);
    }
}
