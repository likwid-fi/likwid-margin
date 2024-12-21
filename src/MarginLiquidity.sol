// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC6909Claims} from "v4-core/ERC6909Claims.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";

contract MarginLiquidity is IMarginLiquidity, ERC6909Claims, Owned {
    uint256 public constant LP_FLAG = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0;

    mapping(address => bool) public hooks;

    constructor(address initialOwner) Owned(initialOwner) {}

    modifier onlyHook() {
        require(hooks[msg.sender], "UNAUTHORIZED");
        _;
    }

    function _getPoolId(PoolId poolId) internal pure returns (uint256 uPoolId) {
        uPoolId = uint256(PoolId.unwrap(poolId)) & LP_FLAG;
    }

    function _getPoolSupplies(address hook, uint256 uPoolId)
        internal
        view
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1)
    {
        uPoolId = uPoolId & LP_FLAG;
        totalSupply = balanceOf[hook][uPoolId];
        uint256 lPoolId = uPoolId + 1;
        retainSupply0 = retainSupply1 = balanceOf[hook][lPoolId];
        lPoolId = uPoolId + 2;
        retainSupply0 += balanceOf[hook][lPoolId];
        lPoolId = uPoolId + 3;
        retainSupply1 += balanceOf[hook][lPoolId];
    }

    // ******************** OWNER CALL ********************
    function addHooks(address _hook) external onlyOwner {
        hooks[_hook] = true;
    }

    // ********************  HOOK CALL ********************
    function mint(address receiver, uint256 id, uint256 amount) external onlyHook {
        unchecked {
            _mint(receiver, id, amount);
        }
    }

    function burn(address sender, uint256 id, uint256 amount) external onlyHook {
        unchecked {
            _burn(sender, id, amount);
        }
    }

    function addLiquidity(address receiver, uint256 id, uint8 level, uint256 amount) external onlyHook {
        uint256 levelId = (id & LP_FLAG) + level;
        unchecked {
            _mint(msg.sender, id, amount);
            _mint(msg.sender, levelId, amount);
            _mint(receiver, levelId, amount);
        }
    }

    function removeLiquidity(address sender, uint256 id, uint8 level, uint256 amount) external onlyHook {
        uint256 levelId = (id & LP_FLAG) + level;
        unchecked {
            _burn(msg.sender, id, amount);
            _burn(msg.sender, levelId, amount);
            _burn(sender, levelId, amount);
        }
    }

    function getSupplies(uint256 uPoolId)
        external
        view
        onlyHook
        returns (uint256 totalSupply, uint256 retainSupply0, uint256 retainSupply1)
    {
        (totalSupply, retainSupply0, retainSupply1) = _getPoolSupplies(msg.sender, uPoolId);
    }

    // ******************** EXTERNAL CALL ********************
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

    function getLevelPool(uint256 uPoolId, uint8 level) external pure returns (uint256 lPoolId) {
        lPoolId = (uPoolId & LP_FLAG) + level;
    }

    function getPoolLiquidities(PoolId poolId, address owner) external view returns (uint256[4] memory liquidities) {
        uint256 uPoolId = uint256(PoolId.unwrap(poolId)) & LP_FLAG;
        for (uint256 i = 0; i < 4; i++) {
            uint256 lPoolId = uPoolId + 1 + i;
            liquidities[i] = balanceOf[owner][lPoolId];
        }
    }
}
