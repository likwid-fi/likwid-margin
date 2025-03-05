// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC6909Claims} from "v4-core/ERC6909Claims.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
// Local
import {HookStatus} from "./types/HookStatus.sol";
import {LiquidityLevel} from "./libraries/LiquidityLevel.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";

contract MarginLiquidity is IMarginLiquidity, ERC6909Claims, Owned {
    using LiquidityLevel for uint8;

    uint8 public protocolRatio;
    mapping(address => bool) public hooks;

    constructor(address initialOwner) Owned(initialOwner) {
        protocolRatio = 99; // 1/(protocolRatio+1)
    }

    modifier onlyHooks() {
        require(hooks[msg.sender], "UNAUTHORIZED");
        _;
    }

    function _getPoolId(PoolId poolId) internal pure returns (uint256 uPoolId) {
        uPoolId = uint256(PoolId.unwrap(poolId)) & LiquidityLevel.LP_FLAG;
    }

    function _getPoolSupplies(address hook, uint256 uPoolId)
        internal
        view
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1)
    {
        uPoolId = uPoolId & LiquidityLevel.LP_FLAG;
        totalSupply = balanceOf[hook][uPoolId];
        uint256 lPoolId = uPoolId + LiquidityLevel.NO_MARGIN;
        retainSupply0 = retainSupply1 = balanceOf[hook][lPoolId];
        lPoolId = uPoolId + LiquidityLevel.ONE_MARGIN;
        retainSupply0 += balanceOf[hook][lPoolId];
        lPoolId = uPoolId + LiquidityLevel.ZERO_MARGIN;
        retainSupply1 += balanceOf[hook][lPoolId];
    }

    // ******************** OWNER CALL ********************
    function addHooks(address _hook) external onlyOwner {
        hooks[_hook] = true;
    }

    // ********************  HOOK CALL ********************
    function mint(address receiver, uint256 id, uint256 amount) external onlyHooks {
        unchecked {
            _mint(receiver, id, amount);
        }
    }

    function burn(address sender, uint256 id, uint256 amount) external onlyHooks {
        unchecked {
            _burn(sender, id, amount);
        }
    }

    function addLiquidity(address receiver, uint256 id, uint8 level, uint256 amount) external onlyHooks {
        uint256 levelId = level.getLevelId(id);
        unchecked {
            _mint(msg.sender, id, amount);
            _mint(msg.sender, levelId, amount);
            _mint(receiver, levelId, amount);
        }
    }

    function removeLiquidity(address sender, uint256 id, uint8 level, uint256 amount) external onlyHooks {
        uint256 levelId = level.getLevelId(id);
        unchecked {
            _burn(msg.sender, id, amount);
            _burn(msg.sender, levelId, amount);
            _burn(sender, levelId, amount);
        }
    }

    function getSupplies(uint256 uPoolId)
        external
        view
        onlyHooks
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1)
    {
        (totalSupply, retainSupply0, retainSupply1) = _getPoolSupplies(msg.sender, uPoolId);
    }

    function getFlowReserves(PoolId poolId, HookStatus memory status)
        external
        view
        onlyHooks
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

    function getPoolSupplies(address hook, PoolId poolId)
        external
        view
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1)
    {
        uint256 uPoolId = _getPoolId(poolId);
        (totalSupply, retainSupply0, retainSupply1) = _getPoolSupplies(hook, uPoolId);
    }

    function getPoolLiquidities(PoolId poolId, address owner) external view returns (uint256[4] memory liquidities) {
        uint256 uPoolId = uint256(PoolId.unwrap(poolId));
        for (uint256 i = 0; i < 4; i++) {
            uint256 lPoolId = uint8(1 + i).getLevelId(uPoolId);
            liquidities[i] = balanceOf[owner][lPoolId];
        }
    }
}
