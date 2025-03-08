// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC6909Claims} from "v4-core/ERC6909Claims.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
// Local
import {LiquidityLevel} from "./libraries/LiquidityLevel.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";

contract MarginLiquidity is IMarginLiquidity, ERC6909Claims, Owned {
    using LiquidityLevel for *;
    using UQ112x112 for *;

    mapping(address => bool) public poolManagers;
    mapping(uint256 => uint256) private liquidityBlockStore;
    uint24 private maxSliding = 5000; // 0.5%
    uint256 public level2InterestRatioX112 = UQ112x112.Q112;
    uint256 public level3InterestRatioX112 = UQ112x112.Q112;
    uint256 public level4InterestRatioX112 = UQ112x112.Q112;

    constructor(address initialOwner) Owned(initialOwner) {}

    modifier onlyPoolManager() {
        require(poolManagers[msg.sender], "UNAUTHORIZED");
        _;
    }

    function getMaxSliding() external view returns (uint24) {
        return maxSliding;
    }

    function _getPoolId(PoolId poolId) internal pure returns (uint256 uPoolId) {
        uPoolId = uint256(PoolId.unwrap(poolId)).getPoolId();
    }

    function _getPoolSupplies(address pool, uint256 uPoolId)
        internal
        view
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1)
    {
        uPoolId = uPoolId & LiquidityLevel.LP_FLAG;
        totalSupply = balanceOf[pool][uPoolId];
        uint256 lPoolId = uPoolId + LiquidityLevel.NO_MARGIN;
        retainSupply0 = retainSupply1 = balanceOf[pool][lPoolId];
        lPoolId = uPoolId + LiquidityLevel.ONE_MARGIN;
        retainSupply0 += balanceOf[pool][lPoolId];
        lPoolId = uPoolId + LiquidityLevel.ZERO_MARGIN;
        retainSupply1 += balanceOf[pool][lPoolId];
    }

    // ******************** OWNER CALL ********************
    function addPoolManager(address _manager) external onlyOwner {
        poolManagers[_manager] = true;
    }

    function setMaxSliding(uint24 _maxSliding) external onlyOwner {
        maxSliding = _maxSliding;
    }

    // ********************  HOOK CALL ********************
    function mint(address receiver, uint256 id, uint256 amount) external onlyPoolManager {
        unchecked {
            _mint(receiver, id, amount);
        }
    }

    function burn(address sender, uint256 id, uint256 amount) external onlyPoolManager {
        unchecked {
            _burn(sender, id, amount);
        }
    }

    function _updateLevelRatio(address pool, uint256 id, uint256 liquidity0, uint256 liquidity1) internal {
        uint256 level4Id = LiquidityLevel.BOTH_MARGIN.getLevelId(id);
        uint256 total4Liquidity = balanceOf[msg.sender][level4Id];
        uint256 level4Liquidity;
        if (liquidity0 > 0) {
            uint256 level2Id = LiquidityLevel.ONE_MARGIN.getLevelId(id);
            uint256 total2Liquidity = balanceOf[msg.sender][level2Id];
            uint256 level2Liquidity = Math.mulDiv(liquidity0, total2Liquidity, total2Liquidity + total4Liquidity);
            level4Liquidity = level4Liquidity + liquidity0 - level2Liquidity;
            level2InterestRatioX112 = level2InterestRatioX112.growRatioX112(level2Liquidity, total2Liquidity);
            _mint(pool, level2Id, level2Liquidity);
        }
        if (liquidity1 > 0) {
            uint256 level3Id = LiquidityLevel.ONE_MARGIN.getLevelId(id);
            uint256 total3Liquidity = balanceOf[msg.sender][level3Id];
            uint256 level3Liquidity = Math.mulDiv(liquidity0, total3Liquidity, total3Liquidity + total4Liquidity);
            level4Liquidity = level4Liquidity + liquidity0 - level3Liquidity;
            level3InterestRatioX112 = level3InterestRatioX112.growRatioX112(level3Liquidity, total3Liquidity);
            _mint(pool, level3Id, level3Liquidity);
        }
        level4InterestRatioX112 = level4InterestRatioX112.growRatioX112(level4Liquidity, total4Liquidity);
        _mint(pool, level4Id, level4Liquidity);
    }

    function addInterests(PoolId poolId, uint256 _reserve0, uint256 _reserve1, uint256 interest0, uint256 interest1)
        external
        onlyPoolManager
        returns (uint256 liquidity)
    {
        uint256 rootK = Math.sqrt(uint256(_reserve0) * _reserve1);
        uint256 rootKLast = Math.sqrt(uint256(_reserve0 + interest0) * uint256(_reserve1 + interest1));
        if (rootK > rootKLast) {
            uint256 id = _getPoolId(poolId);
            uint256 uPoolId = id.getPoolId();
            uint256 _totalSupply = balanceOf[msg.sender][uPoolId];
            uint256 numerator = _totalSupply * (rootK - rootKLast);
            uint256 denominator = rootK + rootKLast;
            liquidity = numerator / denominator;
            if (liquidity > 0) {
                _mint(msg.sender, uPoolId, liquidity);
                denominator = interest0 + Math.mulDiv(interest1, _reserve0, _reserve1);
                uint256 liquidity0 = liquidity * Math.mulDiv(liquidity, interest0, denominator);
                uint256 liquidity1 = liquidity - liquidity0;
                _updateLevelRatio(msg.sender, id, liquidity0, liquidity1);
            }
        }
    }

    function addLiquidity(address receiver, uint256 id, uint8 level, uint256 amount)
        external
        onlyPoolManager
        returns (uint256 liquidity)
    {
        liquidityBlockStore[id] = block.number;
        uint256 levelId = level.getLevelId(id);
        uint256 uPoolId = id.getPoolId();
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

    function _burnEx(address sender, uint256 id, uint256 amount) internal {
        amount = Math.min(balanceOf[sender][id], amount);
        _burn(sender, id, amount);
    }

    function removeLiquidity(address sender, uint256 id, uint8 level, uint256 amount)
        external
        onlyPoolManager
        returns (uint256 liquidity)
    {
        require(liquidityBlockStore[id] < block.number, "NOT_ALLOWED");
        uint256 levelId = level.getLevelId(id);
        uint256 uPoolId = id.getPoolId();
        address pool = msg.sender;
        if (level == LiquidityLevel.ONE_MARGIN) {
            liquidity = amount.mulRatioX112(level2InterestRatioX112);
        } else if (level == LiquidityLevel.ZERO_MARGIN) {
            liquidity = amount.mulRatioX112(level3InterestRatioX112);
        } else if (level == LiquidityLevel.BOTH_MARGIN) {
            liquidity = amount.mulRatioX112(level4InterestRatioX112);
        }
        unchecked {
            _burnEx(pool, uPoolId, liquidity);
            _burnEx(pool, levelId, liquidity);
            _burnEx(sender, levelId, amount);
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

    function getFlowReserves(PoolId poolId, PoolStatus memory status)
        external
        view
        onlyPoolManager
        returns (uint256 reserve0, uint256 reserve1)
    {
        uint256 uPoolId = _getPoolId(poolId);
        (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1) = _getPoolSupplies(msg.sender, uPoolId);
        reserve0 = Math.mulDiv(totalSupply - retainSupply0, status.realReserve0, totalSupply);
        reserve1 = Math.mulDiv(totalSupply - retainSupply1, status.realReserve1, totalSupply);
    }

    // ********************  EXTERNAL CALL ********************
    function getPoolId(PoolId poolId) external pure returns (uint256 uPoolId) {
        uPoolId = _getPoolId(poolId);
    }

    function getPoolSupplies(address pool, PoolId poolId)
        external
        view
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1)
    {
        uint256 uPoolId = _getPoolId(poolId);
        (totalSupply, retainSupply0, retainSupply1) = _getPoolSupplies(pool, uPoolId);
    }

    function getPoolLiquidities(PoolId poolId, address owner) external view returns (uint256[4] memory liquidities) {
        uint256 uPoolId = uint256(PoolId.unwrap(poolId));
        for (uint256 i = 0; i < 4; i++) {
            uint256 lPoolId = uint8(1 + i).getLevelId(uPoolId);
            liquidities[i] = balanceOf[owner][lPoolId];
        }
    }
}
